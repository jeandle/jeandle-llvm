//===- PartialEscapeAnalysis.cpp - PEA (analysis pass) --------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
// Partial Escape Analysis, after Stadler et al., "Partial Escape Analysis and
// Scalar Replacement for Java" (CGO 2014). Tracks Java objects as
// addrspace(1) pointers that are allocated at InvokeInst sites to
// jeandle.new_instance / jeandle.new_array and have not yet escaped. On an
// escape point (generic call, ret, store into non-virtual memory, ...) a
// Materialize effect is recorded. The transform reuses the original
// allocation at its original site, then replays tracked field stores and
// surviving monitorenters before the escape. NeverEscape source allocations
// can instead be deleted. Effects are polymorphic data records
// (jeandle::Effect subclasses): the analysis cannot mutate the IR it walks,
// so every decision is ledgered as an effect. The transform applies ordinary
// effects first, each complete deopt-pool transaction second, and allocation
// cfg-kill effects last. "Control-flow-rewriting" (Materialize's
// splitBasicBlock and CreatePHI's PHI insertion) remains an ordinary effect:
// it only rewrites structure inside blocks that stay alive, whereas a
// cfg-kill effect removes a CFG edge outright.
//
// Per-block exit state (virtual set, field values, lock counts) is snapshotted
// into BlockExits; at each block header we inherit a single pred's snapshot or
// run mergeStates() over all preds. Compatible virtual states remain virtual;
// differing scalar fields are merged with PHIs. Mixed virtual/materialized
// states, incompatible fields, or incompatible lock states materialize the
// virtual predecessor contributions. Ineligibility is reserved for shapes
// that the analysis cannot represent or replay safely.
//
// At multi-pred merges, explicit LLVM PHIs of heap pointers are classified:
// Case A (a non-virtual incoming or a Case-C bail) materializes each virtual
// incoming at its pred; Case B (uniform ObjectID, still virtual) registers the
// PHI as an alias; Case C (distinct but compatible IDs) synthesizes one VO
// cloned from the first per-pred VO. If that synthetic later escapes, its
// ordinary leaf allocations remain at their original sites and its complete
// current state is replayed once onto the pointer PHI.
//
//===----------------------------------------------------------------------===//

#include "llvm/Analysis/Jeandle/PartialEscapeAnalysis.h"

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/ADT/SCCIterator.h"
#include "llvm/ADT/STLFunctionalExtras.h"
#include "llvm/ADT/ScopeExit.h"
#include "llvm/ADT/SmallBitVector.h"
#include "llvm/ADT/Statistic.h"
#include "llvm/Analysis/CFG.h"
#include "llvm/Analysis/ConstantFolding.h"
#include "llvm/Analysis/Jeandle/DeoptPoolBundleLowering.h"
#include "llvm/Analysis/Jeandle/DeoptPoolPlanner.h"
#include "llvm/Analysis/Jeandle/PartialEscape.h"
#include "llvm/Analysis/Jeandle/PartialEscapeUtils.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/IR/BasicBlock.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/InstrTypes.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/IR/Jeandle/JavaType.h"
#include "llvm/IR/Jeandle/JeandleUtils.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Operator.h"
#include "llvm/Support/CheckedArithmetic.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/ErrorHandling.h"

#include <limits>
#include <unordered_map>

#define DEBUG_TYPE "partial-escape-analysis"

using namespace llvm;

// Per-statistic counters surfaced via LLVM's standard `-stats` flag
// (Statistic.h). Emission sites bump attempt-local counters, which are
// published only after the analysis attempt validates. Loop rollback and
// late effect filtering can discard an effect that was already counted, so
// these counters diagnose analysis activity rather than audit the final plan.
STATISTIC(JeandlePEAVirtualized, "Number of virtual objects PEA created");
STATISTIC(JeandlePEAEliminated,
          "Number of allocations eliminated (erased) by PEA");
STATISTIC(JeandlePEAMaterialized, "Number of materializations emitted by PEA");
STATISTIC(JeandlePEAMaterializedPHI,
          "Materializations triggered by PHI / Case-A merge");
STATISTIC(JeandlePEAMaterializedMerge,
          "Materializations triggered by state merge");
STATISTIC(JeandlePEAMaterializedLoopExit,
          "Materializations at loop preheader (force-drain)");
STATISTIC(JeandlePEAMaterializedUnhandled,
          "Materializations for unhandled instruction (escape point)");
// Extended counters. The first three measure how aggressively
// the analyzer drives its loop fixpoint, and so help calibrate
// MaxLoopFixpointIters / JeandlePEALoopCutoff. The last two split the
// "Unhandled" bucket so cascade and nested materializations can be
// audited separately from the user-visible escape-point reason.
STATISTIC(JeandlePEALoopFixpointRetries,
          "Sum of inner-fixpoint iterations across every processLoop call");
STATISTIC(JeandlePEAOuterFixpointIterations,
          "Top-level processLoop entries (one per top-level loop traversal)");
STATISTIC(JeandlePEAModeEscalations,
          "Regular -> MaterializeAll mode flips (escalations)");
STATISTIC(JeandlePEAMaterializedCascade,
          "Materializations triggered by strict-lock cascade");
STATISTIC(JeandlePEAMaterializedNested,
          "Materializations triggered by nested-virtual prerequisite");

// When set, dump per-function PEA classification stats
// on errs() after commit(). The line is prefixed with `;; PEA stats` so it
// is greppable both as IR-comment-shaped output and as a regular stderr
// line. Counts are derived from PEAResult::EscapeClassification (populated
// by commit()).
static llvm::cl::opt<bool> JeandleDumpPEAStats(
    "jeandle-dump-pea-stats", llvm::cl::init(false), llvm::cl::Hidden,
    llvm::cl::desc("PEA: dump per-function NeverEscapes / PartiallyEscapes "
                   "/ AlwaysEscapes counts on errs() after analysis."));

// Eliminate balanced monitor enter/exit pairs on virtual receivers. The JDK
// forwards its JeandleEliminateLocks VM flag here; opt users set it directly.
static llvm::cl::opt<bool> JeandlePEAEliminateLocks(
    "jeandle-pea-eliminate-locks", llvm::cl::init(true), llvm::cl::Hidden,
    llvm::cl::desc("PEA: eliminate balanced monitor enter/exit pairs on "
                   "virtual (non-escaping) receivers."));

// Cascade other still-locked virtuals at materialization when the target uses
// HotSpot's lightweight locking (LM_LIGHTWEIGHT requires strict lock nesting).
// Resolved per-run by resolveStrictLockOrder(): explicit cl override wins,
// otherwise the RequiresStrictLockOrder VMCallback is consulted; final
// fallback is true (JDK 21+ x86_64 default).
static llvm::cl::opt<bool> JeandleAssumeStrictLockOrder(
    "jeandle-assume-strict-lock-order", llvm::cl::init(true), llvm::cl::Hidden,
    llvm::cl::desc("PEA: testing override for whether the target VM requires "
                   "strict lock nesting (cascades still-locked virtuals on "
                   "materialization). When unset, the value is queried from "
                   "the RequiresStrictLockOrder VM callback."));

// Cap on array length for virtualization candidates (default 128). Hidden
// cl::opt so tests can override without rebuilding.
static llvm::cl::opt<unsigned> MaximumEscapeAnalysisArrayLength(
    "jeandle-pea-max-array-length", llvm::cl::init(128), llvm::cl::Hidden,
    llvm::cl::desc("PEA: cap on array length eligible for virtualization. "
                   "Larger arrays bypass PEA. Default 128."));

// Testing-only knob: when true, every top-level processLoop entry switches to
// Mode::MaterializeAll for the whole fixpoint, exercising the deferred
// end-of-block Materialize emission path without constructing a pathological
// non-converging fixpoint. Default off; not surfaced to the VM.
static llvm::cl::opt<bool> JeandlePEAForceMaterializeAll(
    "jeandle-pea-force-materialize-all", llvm::cl::init(false),
    llvm::cl::Hidden,
    llvm::cl::desc("PEA: force every top-level processLoop into "
                   "Mode::MaterializeAll on entry. Testing aid for "
                   "virtualize-then-materialise coverage."));

// Inner B/B' body-pass cap. The default preserves the production policy;
// tests can lower it to exercise whole-attempt recovery without constructing
// a pathological non-converging abstract state.
static llvm::cl::opt<unsigned> JeandlePEALoopFixpointMaxIters(
    "jeandle-pea-loop-fixpoint-max-iters", llvm::cl::init(10), llvm::cl::Hidden,
    llvm::cl::desc("PEA: maximum loop body traversals in one inner B/B' "
                   "fixpoint attempt. Must be at least 1. Default 10."));

// Loop nesting DEPTH threshold. When a top-level processLoop encounters a
// nest whose maximum depth exceeds this value, the analyzer transiently
// enters Mode::StopNewInLoopNest: processAllocation refuses NEW virtual
// allocations inside the nest, but all other operations continue. Bounds the
// worst-case cost of a deep nest while preserving virtualization for objects
// allocated outside it. Default 20. Distinct from
// JeandlePEALoopFixpointMaxIters, which caps body traversals within a single
// fixpoint attempt.
static llvm::cl::opt<unsigned> JeandlePEALoopCutoff(
    "jeandle-pea-loop-cutoff", llvm::cl::init(20), llvm::cl::Hidden,
    llvm::cl::desc("PEA: loop nesting depth threshold. When a nest's maximum "
                   "depth exceeds this value, the analyzer enters the "
                   "Mode::StopNewInLoopNest state for the duration of the "
                   "nest (refuse new virtualisations but keep tracking "
                   "existing virtuals). Default 20."));

// Filter PEA to functions whose name contains a given substring.
// When the option is non-empty, Analyzer::run() returns an empty PEAResult
// for any function whose name does not contain the filter; the transform
// pass then sees nothing to commit. Empty (the default) means "analyze
// every Java method". Used to focus PEA on a specific compilation, and by
// lit tests that want to exercise gating.
static llvm::cl::opt<std::string> JeandleEscapeAnalyzeOnly(
    "jeandle-pea-analyze-only", llvm::cl::init(""), llvm::cl::Hidden,
    llvm::cl::desc("PEA: only analyze functions whose name contains the "
                   "supplied substring. Empty (the default) analyzes every "
                   "Java method gated by jeandle.java_method_compilation."));

static llvm::cl::list<std::string> JeandleEscapeAnalyzeFunctions(
    "jeandle-pea-analyze-function", llvm::cl::Hidden,
    llvm::cl::desc("PEA: only analyze functions whose name exactly matches "
                   "one of the supplied names. May be repeated. Empty (the "
                   "default) preserves substring-filter behavior."),
    llvm::cl::value_desc("function"));

static bool matchesExactAnalyzeFunction(llvm::StringRef FunctionName) {
  if (JeandleEscapeAnalyzeFunctions.empty())
    return true;
  for (const std::string &Allowed : JeandleEscapeAnalyzeFunctions)
    if (FunctionName == llvm::StringRef(Allowed))
      return true;
  return false;
}

// Per-effect dbgs() trace. The cl::opt itself lives in
// PartialEscape.cpp (the centralised effect-emission site at
// PEAResult::addBlockEffect is the only consumer), so no declaration is
// needed in this translation unit. Turn on with -jeandle-trace-pea for
// lit-time diagnostics.

AnalysisKey PartialEscapeAnalysis::Key;

namespace {

// Frontend-invariant verifier for raw object-header accesses. The frontend
// must keep every mark/klass-word access inside a lower-phase >= 1 JavaOp
// that PEA folds by name (load_klass, the monitor ops, arraylength, ...); a
// raw header access reaching the analyzer can only force conservative
// materialization. Off skips the check; Warn reports each violation on
// errs() and keeps the conservative behavior; Fatal aborts the compile.
// Defaults to Fatal in asserts builds to catch frontend regressions loudly,
// Off in release builds (zero cost, conservative behavior preserved).
enum class HeaderAccessCheck { Off, Warn, Fatal };
static llvm::cl::opt<HeaderAccessCheck> JeandlePEAVerifyHeaderAccess(
    "jeandle-pea-verify-header-access",
    llvm::cl::values(
        clEnumValN(HeaderAccessCheck::Off, "off",
                   "Do not check for raw object-header accesses"),
        clEnumValN(HeaderAccessCheck::Warn, "warn",
                   "Report each raw object-header access without aborting"),
        clEnumValN(HeaderAccessCheck::Fatal, "fatal",
                   "Abort the compile on any raw object-header access")),
#ifndef NDEBUG
    llvm::cl::init(HeaderAccessCheck::Fatal),
#else
    llvm::cl::init(HeaderAccessCheck::Off),
#endif
    llvm::cl::Hidden,
    llvm::cl::desc("PEA: verify that no raw object-header memory access "
                   "(constant byte offset < "
                   "instanceOopDesc.base_offset_in_bytes through a virtual "
                   "instance receiver) reaches the analyzer. Arrays are "
                   "exempt: a sub-base constant offset can arise from a "
                   "constant negative array index, a designed "
                   "out-of-bounds case."));

// A live (still-unbalanced) monitorenter on a virtual object.
//   * Call is the original jeandle.monitorenter call site (used by
//     materializeAt to undo the ReplaceCall elision).
//   * BytecodeDepth is the CFG-derived absolute lock-nesting depth used by the
//     strict-lock cascade and merge-time stack-identity comparison. It is a
//     function-wide call-site property and is stable across loop iterations.
// Cascade decisions and merge-time stack-identity compare BytecodeDepth.
struct LockEnter {
  llvm::CallBase *Call;
  uint32_t BytecodeDepth;
};

using FieldDefinitionSet = SmallDenseSet<StoreInst *, 2>;
using FieldDefinitionMap =
    DenseMap<jeandle::ObjectID, DenseMap<int64_t, FieldDefinitionSet>>;

// Function-wide monitor nesting reconstructed from the current LLVM CFG.
// EnterRelativeDepth records the signed depth immediately before each
// monitorenter. EntryDepth is normally zero; OSR roots may infer a uniform
// nonnegative offset for interpreter-held monitors from their real exits.
struct MonitorDepthInfo {
  bool Valid = true;
  DenseMap<CallBase *, int64_t> EnterRelativeDepth;
  uint32_t EntryDepth = 0;
};

// True iff BB ends a compilation via deoptimization. A deopt continuation
// never returns to compiled code, so it is not a "real exit" for monitor
// depth accounting even when its terminator is a return-like instruction.
static bool isDeoptContinuation(const BasicBlock *BB) {
  for (const Instruction &I : *BB)
    if (const auto *CB = dyn_cast<CallBase>(&I))
      if (const Function *Fn = CB->getCalledFunction())
        if (Fn->getIntrinsicID() == Intrinsic::experimental_deoptimize ||
            Fn->getName() == "__llvm_deoptimize")
          return true;
  return false;
}

// Reconstruct the function-wide monitor nesting from the current LLVM CFG:
// assign every monitorenter a signed relative lock depth (enters +1, exits
// -1) by worklist-propagating a per-block incoming depth from the entry
// block. The model is invalidated (Valid=false) by anything the scalar
// depth numbering cannot represent:
//   * a conflicting join (two preds reach a block with different depths) or
//     two visits that assign the same monitorenter different depths;
//   * a callbr monitor operation (no well-defined edge numbering);
//   * a call-form monitor operation that may unwind: a plain call has no
//     explicit exceptional edge, so its depth transition is meaningful only
//     when the call cannot throw. An invoke-form monitor operation instead
//     propagates the adjusted depth on the normal edge and the pre-op depth
//     on the unwind edge, and stops the linear scan of the block.
// Real exits (return/resume/unwind-to-caller, excluding deopt continuations)
// collect their exit depth. For a regular compilation every real exit must
// observe depth 0 and no negative depth may occur: locks are balanced. For
// an OSR compilation the interpreter may already hold monitors at entry, so
// the relative depths are solved for a uniform nonnegative entry offset that
// makes every real exit observe depth 0; when no real exit exists, the
// deepest negative excursion bounds the entry offset from below. All offset
// arithmetic is overflow-checked against the uint32_t wire range of
// BytecodeDepth; any overflow invalidates the model. Callers treat an
// invalid model as "no depth information" and fall back conservatively.
static MonitorDepthInfo computeMonitorDepthInfo(Function &F) {
  MonitorDepthInfo Info;
  DenseMap<BasicBlock *, int64_t> IncomingDepth;
  SmallVector<BasicBlock *, 32> Worklist;
  SmallVector<int64_t, 8> RealExitDepths;
  int64_t MinRelativeDepth = 0;
  int64_t MaxRelativeDepth = 0;

  // Depths are signed and relative to a notional entry depth of 0; the OSR
  // solving below may later shift them by a uniform entry offset. The min/max
  // excursion is tracked so the offset's range can be validated afterwards.
  auto ObserveDepth = [&](int64_t Depth) {
    MinRelativeDepth = std::min(MinRelativeDepth, Depth);
    MaxRelativeDepth = std::max(MaxRelativeDepth, Depth);
  };
  auto Propagate = [&](BasicBlock *Succ, int64_t Depth) {
    auto [It, Inserted] = IncomingDepth.try_emplace(Succ, Depth);
    if (!Inserted) {
      if (It->second != Depth)
        Info.Valid = false;
      return;
    }
    Worklist.push_back(Succ);
  };
  auto RecordEnter = [&](CallBase *CB, int64_t Depth) {
    auto [It, Inserted] = Info.EnterRelativeDepth.try_emplace(CB, Depth);
    if (!Inserted && It->second != Depth)
      Info.Valid = false;
  };
  auto AdjustDepth = [&](int64_t Depth, bool IsEnter, int64_t &Adjusted) {
    if (IsEnter) {
      if (Depth == std::numeric_limits<int64_t>::max()) {
        Info.Valid = false;
        return;
      }
      Adjusted = Depth + 1;
    } else {
      if (Depth == std::numeric_limits<int64_t>::min()) {
        Info.Valid = false;
        return;
      }
      Adjusted = Depth - 1;
    }
    ObserveDepth(Adjusted);
  };

  BasicBlock *Entry = &F.getEntryBlock();
  IncomingDepth[Entry] = 0;
  Worklist.push_back(Entry);
  for (size_t Index = 0; Index != Worklist.size() && Info.Valid; ++Index) {
    BasicBlock *BB = Worklist[Index];
    int64_t Depth = IncomingDepth.lookup(BB);
    ObserveDepth(Depth);
    bool MonitorInvokeHandled = false;

    for (Instruction &I : *BB) {
      auto *CB = dyn_cast<CallBase>(&I);
      if (!CB)
        continue;
      bool IsEnter = jeandle::pea::isJeandleMonitorEnter(CB);
      bool IsExit = jeandle::pea::isJeandleMonitorExit(CB);
      if (!IsEnter && !IsExit)
        continue;

      if (isa<CallBrInst>(CB)) {
        Info.Valid = false;
        break;
      }
      if (IsEnter)
        RecordEnter(CB, Depth);
      if (!Info.Valid)
        break;

      int64_t Adjusted = Depth;
      AdjustDepth(Depth, IsEnter, Adjusted);
      if (!Info.Valid)
        break;

      if (auto *II = dyn_cast<InvokeInst>(CB)) {
        // The operation has completed only on the normal edge. The unwind
        // edge observes the depth immediately before the monitor operation.
        Propagate(II->getNormalDest(), Adjusted);
        Propagate(II->getUnwindDest(), Depth);
        MonitorInvokeHandled = true;
        break;
      }

      // A call-form monitor operation has no explicit exceptional edge, so
      // its scalar depth transition is meaningful only when it cannot unwind.
      Function *DirectCallee = CB->getCalledFunction();
      if (!CB->doesNotThrow() &&
          (!DirectCallee || !DirectCallee->doesNotThrow())) {
        Info.Valid = false;
        break;
      }
      Depth = Adjusted;
    }
    if (!Info.Valid || MonitorInvokeHandled)
      continue;

    Instruction *Term = BB->getTerminator();
    bool IsRealExit = isa<ReturnInst>(Term) || isa<ResumeInst>(Term);
    if (auto *CRI = dyn_cast<CleanupReturnInst>(Term))
      IsRealExit |= CRI->unwindsToCaller();
    if (auto *CSI = dyn_cast<CatchSwitchInst>(Term))
      IsRealExit |= CSI->unwindsToCaller();
    if (IsRealExit && !isDeoptContinuation(BB))
      RealExitDepths.push_back(Depth);
    for (BasicBlock *Succ : successors(BB))
      Propagate(Succ, Depth);
  }

  if (!Info.Valid)
    return Info;

  // Entry-offset solving. The relative depths above assume entry depth 0.
  // A regular compilation must then be lock-balanced: no negative excursion
  // (a monitorexit without a matching enter) and depth 0 at every real exit.
  // An OSR compilation replaces that check with an equation: the interpreter
  // may hold monitors at the OSR entry, so find the uniform entry offset
  // under which every real exit still observes depth 0. With no real exit
  // there is nothing to solve; the deepest negative excursion is then the
  // smallest offset that keeps every depth nonnegative.
  const bool IsOSR = F.getName().starts_with("__jeandle_osr.");
  uint64_t EntryOffset = 0;
  if (!IsOSR) {
    if (MinRelativeDepth < 0)
      Info.Valid = false;
    for (int64_t ExitDepth : RealExitDepths)
      if (ExitDepth != 0)
        Info.Valid = false;
  } else if (!RealExitDepths.empty()) {
    // Every real exit must agree on the same implied entry offset
    // (-ExitDepth); a positive exit depth (more enters than exits on some
    // path) cannot be fixed by any offset and invalidates the model.
    std::optional<uint64_t> SolvedOffset;
    for (int64_t ExitDepth : RealExitDepths) {
      if (ExitDepth > 0 || ExitDepth == std::numeric_limits<int64_t>::min()) {
        Info.Valid = false;
        break;
      }
      uint64_t Candidate = static_cast<uint64_t>(-ExitDepth);
      if (!SolvedOffset)
        SolvedOffset = Candidate;
      else if (*SolvedOffset != Candidate) {
        Info.Valid = false;
        break;
      }
    }
    if (SolvedOffset)
      EntryOffset = *SolvedOffset;
  } else if (MinRelativeDepth < 0) {
    if (MinRelativeDepth == std::numeric_limits<int64_t>::min())
      Info.Valid = false;
    else
      EntryOffset = static_cast<uint64_t>(-MinRelativeDepth);
  }

  // Range validation: EntryOffset must fit the uint32_t BytecodeDepth wire
  // type, cover the deepest negative excursion, and leave headroom for the
  // deepest positive excursion. Each comparison is shaped to avoid signed
  // overflow before the widening conversion.
  constexpr uint64_t MaxLockDepth = std::numeric_limits<uint32_t>::max();
  if (MinRelativeDepth == std::numeric_limits<int64_t>::min())
    Info.Valid = false;
  if (EntryOffset > MaxLockDepth)
    Info.Valid = false;
  if (Info.Valid) {
    if (MinRelativeDepth < 0 &&
        static_cast<uint64_t>(-MinRelativeDepth) > EntryOffset)
      Info.Valid = false;
    if (MaxRelativeDepth > 0 &&
        EntryOffset + static_cast<uint64_t>(MaxRelativeDepth) > MaxLockDepth)
      Info.Valid = false;
  }
  if (Info.Valid)
    Info.EntryDepth = static_cast<uint32_t>(EntryOffset);
  return Info;
}

// Per-block-exit snapshot of the analyzer's per-object state. We record
// this AFTER processing a block so successors can either inherit directly
// (single live pred) or merge across multiple preds. Keeping the state
// per-block — rather than one global accumulating state — is what makes
// multi-pred merge correct in the presence of branches that mutate the field
// values of a virtual independently.
//
// BlockExitData carries the raw per-object data fields. BlockExitInfo
// inherits from it and adds the exception-edge state-splitting
// book-keeping that lives alongside the normal exit data.
struct BlockExitData {
  // Objects still virtual at block exit.
  DenseSet<jeandle::ObjectID> Virtuals;
  // Objects already materialized on every path reaching this exit.
  DenseSet<jeandle::ObjectID> Materialized;
  // Per-object field values at block exit; an absent offset means "Java
  // default", never "field does not exist".
  DenseMap<jeandle::ObjectID, DenseMap<int64_t, jeandle::FieldValue>>
      FieldStates;
  // Reaching virtualized stores for each current field definition. A store
  // replaces this set in straight-line code; merges union predecessor sets.
  // The values let commit distinguish a dead overwritten store from a
  // definition that a load, materialization, deopt snapshot, or conservative
  // fallback actually observed.
  FieldDefinitionMap FieldDefinitions;
  // Per-object unbalanced-monitor count at block exit; sized identically to
  // LiveLockEnters[ID].
  DenseMap<jeandle::ObjectID, unsigned> LockCounts;
  // Per-object live monitorenter stack at block exit. Each entry is an
  // unbalanced monitorenter call site (i.e. its matching monitorexit hasn't
  // been seen yet on this path) PLUS its BytecodeDepth (see LockEnter). Sized
  // identically to LockCounts[ID]. Used by materializeAt to undo only the
  // path-relevant elisions; the BytecodeDepth powers the narrow cascade rule.
  DenseMap<jeandle::ObjectID, SmallVector<LockEnter, 4>> LiveLockEnters;
};

// Whether one predecessor edge contributes state to its target: Unseen (the
// pred has not published an exit yet), Dead (the edge or the whole pred is
// proven unreachable in this attempt), or Live (carries the pred's exit
// snapshot).
enum class EdgeContributionKind : uint8_t { Unseen, Dead, Live };

// One predecessor's contribution to a successor, as resolved by
// Analyzer::contributionFor. Data is non-null exactly when Kind is Live.
struct EdgeContribution {
  EdgeContributionKind Kind = EdgeContributionKind::Unseen;
  BlockExitData *Data = nullptr;

  static EdgeContribution unseen() { return {}; }
  static EdgeContribution dead() {
    return {EdgeContributionKind::Dead, nullptr};
  }
  static EdgeContribution live(BlockExitData *Data) {
    assert(Data && "live edge contribution requires exit data");
    return {EdgeContributionKind::Live, Data};
  }

  bool isUnseen() const { return Kind == EdgeContributionKind::Unseen; }
  bool isDead() const { return Kind == EdgeContributionKind::Dead; }
  bool isLive() const { return Kind == EdgeContributionKind::Live; }
};

// What establishes a CFG deadness proof: a branch/switch condition folded to
// a constant through the scalar-alias plan, a folded invoke JavaOp the
// transform replaces with an unconditional branch, or a virtualized
// allocation invoke whose unwind edge dies with the allocation.
enum class CFGDeadnessProofKind : uint8_t {
  FoldedTerminatorCondition,
  FoldedInvoke,
  EliminatedAllocationInvoke,
};

// A non-literal fact used to classify one or more CFG edges as dead during an
// analysis attempt. Killer is the stable, in-IR suppression key. Condition is
// populated for branch/switch proofs and identifies the value whose surviving
// replacement must still select the same successor after effect filtering.
// ChosenSuccessor is the successor the folded condition selects.
struct CFGDeadnessProof {
  CFGDeadnessProofKind Kind;
  Instruction *Killer;
  Value *Condition = nullptr;
  BasicBlock *ChosenSuccessor = nullptr;
};

// Attempt-local counterparts of the STATISTIC counters above. Emission sites
// bump these freely; publish() folds them into the global counters only after
// the analysis attempt validates.
struct PEAAttemptStatistics {
  uint64_t Virtualized = 0;
  uint64_t Eliminated = 0;
  uint64_t Materialized = 0;
  uint64_t MaterializedPHI = 0;
  uint64_t MaterializedMerge = 0;
  uint64_t MaterializedLoopExit = 0;
  uint64_t MaterializedUnhandled = 0;
  uint64_t LoopFixpointRetries = 0;
  uint64_t OuterFixpointIterations = 0;
  uint64_t ModeEscalations = 0;
  uint64_t MaterializedCascade = 0;
  uint64_t MaterializedNested = 0;

  void publish() const {
    JeandlePEAVirtualized += Virtualized;
    JeandlePEAEliminated += Eliminated;
    JeandlePEAMaterialized += Materialized;
    JeandlePEAMaterializedPHI += MaterializedPHI;
    JeandlePEAMaterializedMerge += MaterializedMerge;
    JeandlePEAMaterializedLoopExit += MaterializedLoopExit;
    JeandlePEAMaterializedUnhandled += MaterializedUnhandled;
    JeandlePEALoopFixpointRetries += LoopFixpointRetries;
    JeandlePEAOuterFixpointIterations += OuterFixpointIterations;
    JeandlePEAModeEscalations += ModeEscalations;
    JeandlePEAMaterializedCascade += MaterializedCascade;
    JeandlePEAMaterializedNested += MaterializedNested;
  }
};

struct BlockExitInfo : BlockExitData {
  // A block reached exclusively through proven-dead incoming edges publishes a
  // dead exit instead of an empty live state. Every successor query then sees
  // Dead and propagates that fact transitively until CFG cleanup removes the
  // structural blocks.
  bool IsDead = false;

  // Exception-edge state-splitting. Only meaningful when the block's
  // terminator is an InvokeInst (which has both a normal and an unwind
  // successor).
  //
  // Jeandle's per-block analyzer processes the terminator-invoke last; the
  // materialize Effects emitted by the invoke are physically inserted
  // immediately before the invoke and survive on BOTH IR successors
  // (definitional dominance). The state-split here is purely about which
  // VirtualMap / FieldStates each successor INHERITS from the analyzer's
  // book-keeping: the normal successor sees the post-call state (the base
  // data of this struct), while the unwind successor sees the pre-call
  // snapshot recorded in UnwindData. A materialize emitted for an invoke
  // executes before the invoke: it replays fields, re-emits locks, and exposes
  // the real object to the callee on both successors. The pre-invoke snapshot
  // is therefore patched to the materialized view for every such object. This
  // prevents an unwind handler from folding a pre-call field value or
  // re-emitting locks, while leaving unrelated virtual objects untouched.
  //
  // TerminatorInvoke / UnwindDest are stashed so contributionFor can detect
  // "this pred's terminator is an invoke whose unwind dest equals the
  // successor block I'm processing".
  llvm::InvokeInst *TerminatorInvoke = nullptr;
  BasicBlock *UnwindDest = nullptr;
  // The invoke was fully virtualized (e.g. processJavaOp emitted a
  // ReplaceCall effect on it). The transform replaces such invokes with an
  // unconditional branch to the normal dest, so the unwind successor receives
  // a Dead contribution while the normal successor remains Live.
  bool UnwindEdgeKilled = false;
  // Pre-invoke snapshot of the per-object data. Captured by processBlock
  // immediately before applying the terminator-invoke, then stashed here
  // only if the post-invoke base data differs (i.e. the invoke actually
  // changed some per-object state, e.g. by materializing an operand).
  // When unset (and UnwindEdgeKilled is false), the unwind successor
  // inherits the same base data as the normal successor (no state-split
  // needed because the invoke was a no-op for PEA).
  std::optional<BlockExitData> UnwindData;
};

// Apply the materialized disposition to an exit-state payload. Field and lock
// data are meaningful only while the object is virtual, so the transition
// drops them together. Call sites decide whether Data is a shared block exit,
// an invoke-unwind snapshot, or a target-local incoming-edge view.
static void rewriteVirtualRefsToMaterialized(
    jeandle::ObjectID ID, Value *MaterializedValue,
    DenseMap<jeandle::ObjectID, DenseMap<int64_t, jeandle::FieldValue>>
        &FieldStates) {
  assert(MaterializedValue && "materialized reference requires a real value");
  for (auto &Other : FieldStates) {
    if (Other.first == ID)
      continue;
    for (auto &Field : Other.second)
      if (Field.second.isVirtualRef() && Field.second.getVirtualRef() == ID)
        Field.second = jeandle::FieldValue::materializedRef(MaterializedValue);
  }
}

// Move ID from Data's virtual set to its materialized set, dropping its
// field, definition, and lock bookkeeping (meaningful only while virtual).
static void markObjectMaterializedDispositionInExitData(BlockExitData &Data,
                                                        jeandle::ObjectID ID) {
  Data.Virtuals.erase(ID);
  Data.Materialized.insert(ID);
  Data.FieldStates.erase(ID);
  Data.FieldDefinitions.erase(ID);
  Data.LockCounts.erase(ID);
  Data.LiveLockEnters.erase(ID);
}

// Apply the full materialized transition for ID in Data: flip the
// disposition, then rewrite every sibling field's VirtualRef(ID) to a
// materialized reference to MaterializedValue.
static void markObjectMaterializedInExitData(BlockExitData &Data,
                                             jeandle::ObjectID ID,
                                             Value *MaterializedValue) {
  markObjectMaterializedDispositionInExitData(Data, ID);
  rewriteVirtualRefsToMaterialized(ID, MaterializedValue, Data.FieldStates);
}

#ifndef NDEBUG
// Debug-only invariant check: every VirtualRef in Data's field states must
// target an object that is still virtual in the same snapshot.
static void assertVirtualReferenceClosure(const BlockExitData &Data) {
  for (const auto &Holder : Data.FieldStates)
    for (const auto &Field : Holder.second) {
      if (!Field.second.isVirtualRef())
        continue;
      jeandle::ObjectID Target = Field.second.getVirtualRef();
      assert(Data.Virtuals.count(Target) &&
             "a VirtualRef target must have a virtual state in the same "
             "block state");
    }
}
#endif

// Resolve the effective "strict lock order" value for one analyzer run.
// Precedence:
//   1. If the JeandleAssumeStrictLockOrder cl::opt was explicitly set on the
//      command line (getNumOccurrences() > 0): honor it (testing override).
//   2. Otherwise, if the RequiresStrictLockOrder VMCallback is registered:
//      call it once and use its value (1 == strict, 0 == relaxed).
//   3. Otherwise (no callback, no override): fall back to the cl::opt's
//      default (true). This keeps lit-test behavior unchanged when no JVM
//      is wired up.
//
// The result is cached for the lifetime of an Analyzer instance, so the
// VMCallback fires at most once per compilation — which keeps the callback
// log's sequential-consistency invariant trivially satisfied (it appears
// exactly once at the start of each compilation's recording, and replay
// matches that ordering).
static bool resolveStrictLockOrder() {
  if (JeandleAssumeStrictLockOrder.getNumOccurrences() > 0)
    return JeandleAssumeStrictLockOrder;
  if (const jeandle::VMCallbacks *CB = jeandle::getVMCallbacks()) {
    if (CB->RequiresStrictLockOrder)
      return CB->RequiresStrictLockOrder() != 0;
  }
  return JeandleAssumeStrictLockOrder;
}

// Collect the basic blocks that form a cycle the loop fixpoint cannot
// converge on: a strongly connected component (or a self-looping block) that
// is not wholly contained in any natural loop known to LoopInfo. Jeandle
// lowered IR can contain such irreducible cycles (e.g. from exception-edge
// tangles); processLoop only runs on LoopInfo loops, so a cycle outside
// every loop would be re-walked by the plain RPO pass with no fixpoint and
// no backedge state. Callers treat these blocks as unsafe for
// virtualization: an allocation whose uses reach them is not virtualized.
static DenseSet<BasicBlock *> findUnsafeReachableCyclicBlocks(Function &F,
                                                              LoopInfo &LI) {
  DenseSet<BasicBlock *> Unsafe;
  for (scc_iterator<Function *> It = scc_begin(&F), End = scc_end(&F);
       It != End; ++It) {
    const std::vector<BasicBlock *> &SCC = *It;
    bool IsCyclic = SCC.size() > 1;
    if (!IsCyclic) {
      BasicBlock *BB = SCC.front();
      IsCyclic = llvm::is_contained(successors(BB), BB);
    }
    if (!IsCyclic)
      continue;

    bool CoveredByLoop = false;
    for (Loop *L = LI.getLoopFor(SCC.front()); L; L = L->getParentLoop()) {
      if (llvm::all_of(SCC, [L](BasicBlock *BB) { return L->contains(BB); })) {
        CoveredByLoop = true;
        break;
      }
    }
    if (!CoveredByLoop)
      Unsafe.insert_range(SCC);
  }
  return Unsafe;
}

// The per-function PEA analyzer; the file header carries the algorithm
// overview. run() walks the function's blocks in a single reverse postorder,
// maintaining the fragmented per-block state (see STATE MODEL below):
// CurrentState plus the analyzer-wide maps keyed by ObjectID. Each block
// rebuilds that state from its predecessors — inheriting one live
// predecessor's snapshot or running the merge fixpoint (mergeStates /
// MergeProcessor) over all of them — then processes its instructions,
// recording every decision as an Effect in Result rather than mutating IR,
// and publishes a BlockExitInfo snapshot. Natural loops are handled by
// processLoop as a B/B' fixpoint over the loop's blocks, with mode
// escalation (Mode::Regular -> StopNewInLoopNest -> MaterializeAll) bounding
// deep or non-converging nests. Structural or eligibility failures do not
// patch history: they either restore a loop snapshot or abandon the attempt
// and retry with monotonic suppression sets (SuppressedCFGProofs /
// SuppressedVirtualizations / the retry-site outputs). commit() then
// validates the surviving effect plan (final deopt obligations, CFG deadness
// proofs, lock balancing) and classifies every allocation site.
class Analyzer {
public:
  Analyzer(Function &F, DominatorTree &DT, LoopInfo &LI, bool StrictLockOrder,
           const DenseSet<Instruction *> &SuppressedCFGProofs,
           const DenseSet<CallBase *> &SuppressedVirtualizations)
      : F(F), DT(DT), LI(LI), DL(F.getParent()->getDataLayout()),
        VMConsts(jeandle::VMConstants::fromModule(*F.getParent())),
        MonitorDepth(computeMonitorDepthInfo(F)),
        StrictLockOrder(StrictLockOrder),
        LockEliminationEnabled(JeandlePEAEliminateLocks),
        SuppressedCFGProofs(SuppressedCFGProofs),
        SuppressedVirtualizations(SuppressedVirtualizations),
        UnsafeCyclicBlocks(findUnsafeReachableCyclicBlocks(F, LI)) {}

  // Run the analysis over F: the RPO walk, commit, and the validation
  // gates. Returns the committed effect plan, or an empty result when the
  // function is filtered out or a validation gate failed (the offending
  // proofs/sites are then exposed via the getters below for a suppressed
  // fresh attempt).
  jeandle::PEAResult run();
  ArrayRef<Instruction *> getInvalidCFGProofKillers() const {
    return InvalidCFGProofKillers;
  }
  bool hasInvalidDeoptObligation() const { return InvalidDeoptObligation; }
  ArrayRef<CallBase *> getInvalidDeoptAllocationSites() const {
    return InvalidDeoptAllocationSites;
  }
  ArrayRef<CallBase *> getRetryVirtualizationAllocationSites() const {
    return RetryVirtualizationAllocationSites;
  }

  // Loop-nest execution mode, a single analyzer-global field consulted by
  // processAllocation and processLoop:
  //   Regular            — processAllocation registers virtuals normally.
  //   StopNewInLoopNest  — processAllocation refuses NEW virtualizations
  //                        inside the active loop nest, but already-virtual
  //                        objects, loads/stores, merges, locks, and exits all
  //                        continue to be tracked exactly as in Regular. The
  //                        outermost processLoop enters this mode nest-wide
  //                        when the nest's maximum depth exceeds
  //                        JeandlePEALoopCutoff (bounding the worst-case cost
  //                        of a deep nest while preserving virtualization for
  //                        objects allocated outside it), and reverts it
  //                        before returning. In this mode, ensureMaterialized
  //                        on a (necessarily outer-scope) virtual object
  //                        latches OverflowFlag to trigger the MaterializeAll
  //                        recovery.
  //   MaterializeAll     — processAllocation registers AND immediately
  //                        schedules an end-of-block materialization for the
  //                        new VO (virtualize-then-materialize), so
  //                        intra-block folds survive. Entered on the first
  //                        non-convergence or overflow of the nest's
  //                        fixpoint; the mode persists through the rest of
  //                        the nest and is reset to Regular only when the
  //                        outermost (depth-1) fixpoint converges.
  enum class Mode : uint8_t { Regular, StopNewInLoopNest, MaterializeAll };

private:
  // The function under analysis and its cached analyses. The IR is never
  // mutated: every planned change is recorded as an Effect in Result.
  Function &F;
  DominatorTree &DT;
  LoopInfo &LI;
  const DataLayout &DL;
  // VMConstants read once from the module's runtime-defined globals (patched by
  // HotSpot's RuntimeDefinedJavaOps::define_global_variables); see
  // llvm/IR/Jeandle/VMConstants.h for the delivery model. Lit tests that never
  // link the template module fall through to the compile-time defaults declared
  // on `struct VMConstants`.
  const jeandle::VMConstants VMConsts;
  // CFG-derived absolute lock-nesting depth of every monitorenter call site
  // (see computeMonitorDepthInfo). Backs the strict-lock cascade and the
  // merge-time lock-stack identity comparison. An invalid model disables
  // depth-based reasoning (getLockDepth returns nullopt).
  const MonitorDepthInfo MonitorDepth;
  // Cached "strict lock order" decision shared by every fresh attempt in this
  // analysis run; see resolveStrictLockOrder() for the precedence rules.
  const bool StrictLockOrder;
  // Whether balanced monitor enter/exit pairs on virtual receivers may be
  // eliminated this run (snapshot of the JeandlePEAEliminateLocks cl::opt at
  // Analyzer construction).
  const bool LockEliminationEnabled;
  // Monotonic cross-attempt suppression sets, owned by the caller and shared
  // by every fresh attempt: terminators whose CFG-deadness proof failed
  // validation, and allocation sites whose virtualization failed or was
  // revoked. A suppressed proof/site is treated conservatively (edge kept
  // live / allocation kept real) so the retried attempt cannot repeat the
  // same unsound plan.
  const DenseSet<Instruction *> &SuppressedCFGProofs;
  const DenseSet<CallBase *> &SuppressedVirtualizations;
  // Blocks in cycles no natural loop covers (see
  // findUnsafeReachableCyclicBlocks); allocations in them are kept real.
  DenseSet<BasicBlock *> UnsafeCyclicBlocks;
  // The plan under construction: virtual objects, per-block effect lists,
  // analyzer-built unparented values, and the final escape classification.
  jeandle::PEAResult Result;
  // Attempt-local statistic counters, published to the global STATISTIC
  // counters only after the attempt validates (see publishAttemptOutputs).
  PEAAttemptStatistics AttemptStats;
  // Attempt outputs, handed to the caller by run() so it can grow the
  // monotonic suppression sets before a fresh retry. InvalidCFGProofKillers:
  // proofs invalidated by validateCFGDeadnessProofs at commit.
  SmallVector<Instruction *, 8> InvalidCFGProofKillers;
  // A final deopt obligation could not be satisfied; the attempt must be
  // abandoned. Polled like InvalidLoopMonotonicity.
  bool InvalidDeoptObligation = false;
  // Allocation sites whose objects the invalid deopt obligation depends on;
  // suppressed on retry.
  SmallVector<CallBase *, 4> InvalidDeoptAllocationSites;
  // Allocation sites to keep real on a fresh retry (markIneligible's
  // FreshRetry path); distinct from the invalid-deopt sites in that the
  // current attempt is abandoned immediately once this is non-empty.
  SmallVector<CallBase *, 4> RetryVirtualizationAllocationSites;
  // Safepoints whose deopt-pool rewrite plan commit() discovered to be
  // invalid after the analysis walk (duplicate pool effects at one
  // safepoint, or plan members/tokens that lost eligibility during
  // commit-time filtering). validateFinalDeoptObligations rejects them,
  // failing the attempt.
  DenseSet<CallBase *> LateInvalidDeoptPools;

  // Attempt-local ledger of every non-literal CFG deadness proof actually
  // consumed by contributionFor. RecordedCFGProofs deduplicates repeated
  // successor queries for the same terminator.
  SmallVector<CFGDeadnessProof, 8> CFGDeadnessProofs;
  DenseSet<Instruction *> RecordedCFGProofs;

  // Per-owner view of Result.BlockEffects, rebuilt lazily when
  // Result.EffectEpoch changes. Lets commit()'s availability sweep
  // (FieldValuesAvailable) and Case-C identity analysis
  // (hasObservableIdentityUse) find an owner's effects by lookup instead of
  // re-scanning every block's EffectList per query.
  DenseMap<jeandle::ObjectID, SmallVector<const jeandle::Effect *, 4>>
      EffectsByOwnerCache;
  // The Result.EffectEpoch value EffectsByOwnerCache was built from;
  // UINT64_MAX forces a rebuild on first use.
  uint64_t EffectsByOwnerCacheEpoch = UINT64_MAX;
  void ensureEffectsByOwnerCache();

  // Memoized deopt-bundle parse. The bundle is immutable during a single
  // analysis attempt (the Analyzer is rebuilt from the original IR each
  // attempt), so parseDeoptBundle is a pure function of the CallBase. Caching
  // avoids re-parsing on every loop-fixpoint re-visit of an in-loop safepoint.
  DenseMap<CallBase *, std::optional<jeandle::pea::ParsedDeoptBundle>>
      DeoptParseCache;

  // ---------------------------------------------------------------------
  // STATE MODEL — a block's PEA state is fragmented across analyzer-wide
  // maps keyed by ObjectID (declared below):
  //   CurrentState (PEABlockState)     the live per-block object set
  //                                    (virtual/materialized markers)
  //   FieldStates[ID][offset]          the per-field values; Jeandle's
  //                                    ObjectState itself carries NO field
  //                                    state
  //   LockCounts[ID] / LiveLockEnters[ID]  the per-object lock stack
  //   Materialized (DenseSet)          the per-path materialized flag. The
  //                                    materialized VALUE is OrigAlloc on
  //                                    every edge under the reuse-OrigAlloc
  //                                    model (it dominates every escape point
  //                                    by SSA), so no per-edge pointer map is
  //                                    kept.
  //   Aliases (AliasMap)               SSA-value -> ObjectID alias map
  //
  // The fragmentation follows from the traversal shape: Jeandle walks LLVM
  // IR in a single RPO pass with per-block snapshots encoded in
  // BlockExitData/BlockExitInfo for the merge fixpoint, and per-field state
  // is inherently sparse and path-dependent (only offsets a store or load
  // actually touched are recorded), so a flat per-ID map per state component
  // beats one cloned per-block state container.
  // TODO(graal-unify): unifying to Graal's single-container model would touch
  // ~every state read/write, snapshot/restore, the merge fixpoint, and
  // LoopSnapshot, with no observable IR benefit.
  // ---------------------------------------------------------------------
  jeandle::AliasMap Aliases;
  // Per-block accumulating object state. Reset at the top of every block from
  // the predecessor snapshots (single inherit / multi-pred merge); rebuilt as
  // the instructions in the block are processed; snapshotted to BlockExits at
  // the end of the block.
  jeandle::PEABlockState CurrentState;

  // Per-object field state: ObjectID -> (offset -> FieldValue). This — not
  // the (field-less) ObjectState — carries every per-field value the analysis
  // tracks. Field discovery is lazy, so this map is deliberately kept
  // decoupled from VirtualObject::Fields (the two are not kept in lock
  // step).
  // Both VirtualObject::Fields and this map are path-dependent: they record
  // only offsets that some store/load actually touched, never the declared
  // field layout. An offset absent here means "Java default" (zero/null), not
  // "field does not exist" — never treat the size of either as a structural
  // invariant of the object's type (see synthesizeCaseC).
  DenseMap<jeandle::ObjectID, DenseMap<int64_t, jeandle::FieldValue>>
      FieldStates;

  // Reaching virtualized-store definitions for FieldStates. This map has the
  // same path-sensitive lifecycle as FieldStates. A straight-line store
  // replaces the reaching set and a merge unions predecessor sets.
  FieldDefinitionMap FieldDefinitions;
  // Definitions observed by a folded load, materialization, deopt snapshot,
  // or explicit fallback. If their owner becomes ineligible, their original
  // stores must survive. Other EliminateStore effects remain valid dead-store
  // elimination even though the owner's allocation is kept real.
  DenseSet<StoreInst *> ObservedFieldStores;
  // Nested identity written by each virtual-reference store. Commit consults
  // this only for observed definitions; unobserved stores are pure dead-store
  // eliminations and need no recorded identity.
  DenseMap<StoreInst *, jeandle::ObjectID> VirtualRefStoreTargets;

  // Per-object eligibility flag. It is function-wide within one traversal:
  // markIneligible retroactively drops every recorded effect for the object,
  // while ordinary use points materialize and preserve earlier folds. A loop
  // retry restores decisions made from an incomplete backedge state. A stable
  // failure abandons the attempt and suppresses its allocation sites in a
  // fresh analysis instead of mutating already-recorded loop states in place.
  DenseMap<jeandle::ObjectID, bool> Eligible;

  // Exact CallBase operand numbers owned by the current safepoint's complete
  // deopt-pool plan. Object identity is deliberately not the key: one SSA
  // value may occur in several semantically different cells, and only cells
  // explicitly rewritten or removed by the immutable plan are non-escaping.
  // This state is ephemeral for one processInstruction dispatch and is not
  // part of loop snapshots; the durable plan lives in the block EffectList.
  CallBase *HandledDeoptCall = nullptr;
  SmallDenseSet<unsigned, 16> HandledDeoptOperandNos;

  // Per-object monitor lock counter. Incremented on a folded monitorenter,
  // decremented on a folded monitorexit. Any object with LockCount != 0 at
  // commit time is marked ineligible (unbalanced locking).
  DenseMap<jeandle::ObjectID, unsigned> LockCounts;

  // Per-block live monitorenter stack per ObjectID. Pushed by a folded
  // monitorenter on the receiver, popped by the matching monitorexit. At any
  // point the stack contains exactly the unbalanced enter call sites whose
  // matching exits haven't been seen yet on this path; size == LockCounts[ID].
  // Reset+inherited per block (same lifecycle as LockCounts) so siblings in
  // a diamond CFG don't share stacks. materializeAt walks this stack to
  // decide which ReplaceCall elisions to undo. Each entry also carries the
  // CFG-derived global BytecodeDepth for its original enter site.
  // back().BytecodeDepth is this VO's innermost lock depth and
  // front().BytecodeDepth is its outermost lock depth.
  DenseMap<jeandle::ObjectID, SmallVector<LockEnter, 4>> LiveLockEnters;

  // Per-path "this object has already been materialized somewhere upstream"
  // set. Materialization is recorded at most once per ObjectID per pred path
  // — the first escape site wins; multi-pred merges that see the object
  // materialized on every incoming carry the Materialized state forward.
  DenseSet<jeandle::ObjectID> Materialized;

  // Synthetic Case-C identity DAGs whose PHIs and backing ordinary allocation
  // sites have passed the complete prepare preflight. This set records only
  // identity readiness; virtual/materialized object state remains path-local.
  DenseSet<jeandle::ObjectID> PreparedSyntheticIDs;
  // Candidate ordinary leaf allocations that back a prepared synthetic
  // identity DAG. At commit, only leaves reachable from a surviving synthetic
  // Materialize effect are classified PartiallyEscapes and kept at their
  // original allocation sites. No source field or lock replay is emitted: the
  // synthetic's point-local MaterializeEffect replays the complete current
  // state once onto SyntheticPhi.
  DenseSet<jeandle::ObjectID> KeptSyntheticSourceAllocations;

  // Per-block exit snapshots, keyed by the block that produced them.
  DenseMap<BasicBlock *, BlockExitInfo> BlockExits;

  // Stable, target-local views of predecessor exits for the current analysis
  // scope. Incoming-edge materialization must be visible while analyzing its
  // target merge without mutating the shared predecessor snapshot seen by
  // sibling successors.
  // The pointees are heap-allocated so collecting another edge cannot
  // invalidate pointers already held by MergeProcessor. The outermost
  // ScopedEdgeExitViews clears the cache on entry and exit, bounding both the
  // copies and their Value* references to one processBlock or direct
  // mergeStates invocation. Nested processBlock -> mergeStates scopes share
  // the same views so merge retries observe their own monotone edge flips.
  DenseMap<BasicBlock *, DenseMap<BasicBlock *, std::unique_ptr<BlockExitData>>>
      EdgeExitViews;
  // Nesting depth of live ScopedEdgeExitViews; the outermost scope owns and
  // clears EdgeExitViews.
  unsigned EdgeExitViewScopeDepth = 0;

  // RAII scope bounding the lifetime of EdgeExitViews to one processBlock or
  // direct mergeStates invocation. The outermost scope clears the cache on
  // entry and exit; nested scopes (processBlock -> mergeStates) share the
  // same views so merge retries observe their own monotone edge flips.
  class ScopedEdgeExitViews {
    Analyzer &A;

  public:
    explicit ScopedEdgeExitViews(Analyzer &A) : A(A) {
      if (A.EdgeExitViewScopeDepth++ == 0)
        A.EdgeExitViews.clear();
    }
    ~ScopedEdgeExitViews() {
      assert(A.EdgeExitViewScopeDepth != 0 &&
             "unbalanced edge-exit-view scope");
      if (--A.EdgeExitViewScopeDepth == 0)
        A.EdgeExitViews.clear();
    }
    ScopedEdgeExitViews(const ScopedEdgeExitViews &) = delete;
    ScopedEdgeExitViews &operator=(const ScopedEdgeExitViews &) = delete;
  };

  // Function-wide dedup of (Pred, TargetMerge, ObjectID) materializations.
  // Multiple merge-time Materialize-at-pred emissions for the same (Pred, M,
  // ID) would otherwise produce duplicate replay effects; this nested map
  // ensures we emit exactly one Materialize effect per (Pred, M, ID) across
  // the entire run. Per-pred mats for distinct target merges M1, M2 at the
  // same PH are NOT deduped (they are distinct edge materializations). A true
  // block-end drain passes M=null, so its (PH, null, ID) entry dedups at that
  // program point. Nested as PH -> M -> ID set so `MaterializedAtPred[PH][M]`
  // is a `DenseSet<ID>&` (bindable to MaterializeContext::MaterializedSet)
  // and the loop rollback's `MaterializedAtPred.erase(BB)` still erases
  // per-PH (all M, all ID).
  DenseMap<BasicBlock *, DenseMap<BasicBlock *, DenseSet<jeandle::ObjectID>>>
      MaterializedAtPred;

  // One final-commit transaction per top-level materialization request.
  // Recursive field prerequisites and strict-lock cascade calls inherit the
  // active ID. Plans are monotonic analysis metadata; rollback may discard all
  // of a plan's effects, in which case commit ignores its member set.
  uint32_t NextMaterializationPlanID = 0;
  uint32_t ActiveMaterializationPlanID =
      jeandle::MaterializeEffect::InvalidPlanID;
  DenseMap<uint32_t, DenseSet<jeandle::ObjectID>> MaterializationPlanMembers;

  // Home block of each analyzer-built (unparented) PHI: the merge/loop-header
  // block the CreatePHI effect will insert it into. The materialize dominance
  // gate (ensureMaterialized) cannot query DT.dominates on an unparented PHI;
  // checking that its HOME block dominates the SafeIP block is the sound
  // equivalent. Populated at every CreatePHI emission site. Entries for PHIs
  // that are rolled back by the loop fixpoint are harmless: the gate only
  // treats a stale entry as "dominates", and a rolled-back PHI is never
  // referenced by surviving state (restoreLoopSnapshot truncates OwnedPhis).
  DenseMap<Value *, BasicBlock *> PhiHome;

  // Per-merge-block deferred CreatePHI effects. mergeStates pushes every
  // CreatePHI it would have committed directly onto this list (keyed by merge
  // block). processBlock drains the list after the merge fixpoint and before
  // walking the block body, assigning each effect a fresh nextSeqNo(). This
  // places CreatePHI after merge-time per-pred Materialize effects and before
  // body effects that may consume the PHI. The first relation matters when
  // the merge block is its own back-edge predecessor, where both effects land
  // in BlockEffects[BB]. Every CreatePHI effect is a field-value PHI: a
  // materialized object never needs a merge PHI because under the
  // reuse-OrigAlloc model OrigAlloc is the single SSA value on every path
  // (such a PHI would trivially fold), and EliminateAllocation never touches
  // the OrigAlloc of a PartiallyEscapes VO.
  DenseMap<BasicBlock *, jeandle::EffectList> PendingMergePhis;

  // Current analyzer mode. Flipped to MaterializeAll by
  // processLoop's overflow retry, or to StopNewInLoopNest at top-level
  // processLoop entry on a nest deeper than JeandlePEALoopCutoff, then
  // reverted before processLoop returns.
  Mode CurrentMode = Mode::Regular;

  // Cross-recursion overflow signal. LLVM is built -fno-exceptions, so the
  // deep-nest abort travels as a polled flag instead of a throw. Latched in
  // ensureMaterialized when CurrentMode == StopNewInLoopNest (a deep nest)
  // and a virtual object is about to be materialized: in StopNewInLoopNest
  // no new virtualizations occur, so such an object must be an outer-scope
  // (pre-loop / outer-loop) allocation, and materializing it would force
  // re-iteration of the whole nest (exponential in nest depth). Nested
  // processLoop calls (depth>1) return immediately when it is already set
  // (propagating the abort outward), and the outermost (depth==1)
  // processLoop catches it, restores the snapshot, drains the preheader, and
  // redoes the nest in MaterializeAll. Cleared on every top-level
  // processLoop entry and consumed (cleared) immediately before the
  // MaterializeAll retry.
  bool OverflowFlag = false;

  // A completed loop traversal must publish every structural loop end, and a
  // loop end that became live cannot become dead on a later non-converged
  // traversal. A violation invalidates the whole analysis attempt; callers
  // poll this flag like OverflowFlag so no half-built state reaches commit().
  bool InvalidLoopMonotonicity = false;

  // Per-block list of VOs registered while CurrentMode was
  // MaterializeAll. processBlockBodyAndPublish drains this list at the
  // block's terminator (before the invoke snapshot) and emits a
  // Materialize effect for each VO at the block's terminator. The
  // deferred emission lets all intra-block loads/stores fold against
  // FieldStates first; the materialize then captures the final field
  // values. The bucket is keyed by BasicBlock so siblings don't collide;
  // loop rollback erases the loop blocks' entries.
  DenseMap<BasicBlock *, SmallVector<jeandle::ObjectID, 4>>
      PendingMaterializeAllVOs;

  // Stable allocation-site -> ObjectID cache. processAllocation consults this
  // before creating a fresh VO so re-processing the same alloc inside a loop
  // fixpoint iteration reuses the original ID (otherwise the convergence
  // check, which compares FieldStates and Virtuals sets across iterations,
  // would diverge forever). Monotonically grown; never cleared.
  DenseMap<CallBase *, jeandle::ObjectID> AllocSiteToVO;

  // Every Loop* on which processLoop was invoked (including recursive
  // sub-loop calls). The safety-net
  // materializePreheaderVirtualsForUnvisitedLoops() drains preheader
  // virtuals ONLY for loops absent from this set, i.e. truly unvisited
  // loops (an unreachable top-level loop the RPO walk skipped, or a
  // sub-loop whose containing top-level loop's processLoop bailed before
  // recursing into it). processLoop handles every loop it visits —
  // converged loops need no drain, while overflow/non-convergence recovery
  // drains in place — so the only loops that need this safety-net drain are
  // those processLoop never ran on.
  DenseSet<Loop *> VisitedLoops;

  // Per-in-loop-block field-PHI cache. Keyed on (BB, ID, Offset) where BB is
  // any merge block inside a loop (loop header OR non-header in-loop merge).
  // The cache returns a STABLE PHINode* across fixpoint iterations so the
  // convergence check on BlockExitInfo.FieldStates can compare FieldValues
  // by Value pointer (otherwise every iteration would synthesize a fresh
  // PHI and the fixpoint would never close). The current B seed and fresh
  // body exits may both reference these PHIs, so the shells live in
  // Result.OwnedLoopFieldPhis and survive rollback while their CreatePHI
  // effects are re-emitted for the current traversal.
  // Cache key identifying one merged field at one in-loop merge block: the
  // merge block BB passed to getOrCreateLoopFieldPhi, the owning ObjectID,
  // and the byte offset of the merged field.
  struct LoopPhiKey {
    BasicBlock *Header;
    jeandle::ObjectID ID;
    int64_t Offset; // byte offset of the merged field
    bool operator==(const LoopPhiKey &O) const {
      return Header == O.Header && ID == O.ID && Offset == O.Offset;
    }
  };
  // std::unordered_map hash adapter for LoopPhiKey.
  struct LoopPhiKeyHash {
    size_t operator()(const LoopPhiKey &K) const {
      return static_cast<size_t>(
          hash_combine(hash_value(K.Header), K.ID, K.Offset));
    }
  };
  std::unordered_map<LoopPhiKey, WeakTrackingVH, LoopPhiKeyHash>
      LoopFieldPhiCache;

  // Per-VO record of LLVM pointer-PHIs that processBlockPhis
  // aliased via Case-B (every incoming agrees on the same ObjectID).
  // commit() consults this to schedule explicit PHI erasures for VOs
  // that end up NeverEscapes, so EliminateAllocation isn't left with
  // a dead-but-still-parented `phi [poison, ..., poison]` survivor
  // in the IR.
  //
  // Intentionally NOT snapshotted in LoopSnapshot/restoreLoopSnapshot: it is
  // commit()-time-only state, and the loop fixpoint re-derives the Case-B
  // alias decision each merge (resetAlias before every decision). Entries can
  // therefore accumulate across iterations; that is benign because the
  // consumer only acts for VOs that are NeverEscapes in the FINAL plan, and
  // the populate site dedups by PHI identity so the erase list never contains
  // a duplicate (which the transform's WeakTrackingVH null-check would in any
  // case skip after the first erase).
  DenseMap<jeandle::ObjectID, SmallVector<llvm::PHINode *, 2>> CaseBPhiAliases;

  // Per-merge driver for one multi-predecessor block. run() collects the
  // predecessor contributions (compacting Live snapshots and keeping the full
  // structural edge list for PHI arity), intersects the tracked ObjectID
  // sets, then drives the merge fixpoint: the per-VO loop and the PHI loop
  // (processBlockPhis / synthesizeCaseC, which remain Analyzer methods) are
  // re-run whenever a nested per-pred materialization invalidates an earlier
  // decision. The fixpoint's deferred CreatePHI effects accumulate in the
  // retry-cleared MergeEffects buffer and are committed to
  // PendingMergePhis[BB] once the merge converges. Reference members alias
  // the Analyzer's per-block state slots so the merge body reads and writes
  // the analyzer's state directly (only method calls are qualified with A.).
  class MergeProcessor {
  public:
    MergeProcessor(Analyzer &A, BasicBlock *BB);
    void run();

  private:
    Analyzer &A;
    // The merge block being processed.
    BasicBlock *BB;
    // Per-merge context: the predecessor exit snapshots and the intersected
    // tracked-ID set. Preds/PredBBs contain Live contributions only.
    // FullPredBBs and FullContributions retain every structural predecessor
    // edge in original order so a deferred field PHI can keep
    // verifier-correct arity while a proven-dead CFG edge still exists.
    // LiveOriginalIndices maps each compact Preds slot back to that
    // structural position. IDs is the intersection of every live
    // predecessor's tracked ObjectIDs: only these may remain unified at BB's
    // entry.
    SmallVector<BlockExitData *, 4> Preds;
    SmallVector<BasicBlock *, 4> PredBBs;
    SmallVector<BasicBlock *, 4> FullPredBBs;
    SmallVector<EdgeContributionKind, 4> FullContributions;
    SmallVector<unsigned, 4> LiveOriginalIndices;
    SmallVector<jeandle::ObjectID, 8> IDs;

    // References to the Analyzer's per-block state. They alias the member
    // SLOTS, so reassigning e.g. CurrentState (the reset/clear retry) writes
    // through to the Analyzer member; clear()/insert() likewise mutate it.
    jeandle::PEABlockState &CurrentState;
    DenseMap<jeandle::ObjectID, DenseMap<int64_t, jeandle::FieldValue>>
        &FieldStates;
    FieldDefinitionMap &FieldDefinitions;
    DenseMap<jeandle::ObjectID, bool> &Eligible;
    DenseMap<jeandle::ObjectID, unsigned> &LockCounts;
    DenseMap<jeandle::ObjectID, SmallVector<LockEnter, 4>> &LiveLockEnters;
    DenseSet<jeandle::ObjectID> &Materialized;
    jeandle::AliasMap &Aliases;
    jeandle::PEAResult &Result;
    DenseMap<BasicBlock *, jeandle::EffectList> &PendingMergePhis;
    // This merge's deferred CreatePHI effects buffer: cleared on every
    // fixpoint retry, committed to PendingMergePhis[BB] after convergence.
    jeandle::EffectList MergeEffects;

    // Intersect the tracked-ID sets of all live predecessors into IDs (sorted
    // for deterministic effect order).
    void intersectVirtualObjects();
    // Union the reaching field definitions of ineligible objects across the
    // predecessors so their surviving stores keep flowing to consumers.
    void mergeIneligibleFieldDefinitions();
    // Merge one object's per-pred disposition (virtual/materialized), lock
    // state, and fields. Returns true when a nested materialization fired and
    // the fixpoint must re-run.
    bool mergeObjectState(jeandle::ObjectID ID);
    // Merge one object's field values across preds, synthesizing field PHIs
    // for disagreeing offsets. Same retry contract as mergeObjectState.
    bool mergeFieldStates(jeandle::ObjectID ID);
    // Materialize ID at every still-virtual pred's terminator, then merge the
    // resulting all-materialized state. Same retry contract.
    bool materializePredsAndMerge(jeandle::ObjectID ID);
    // Pad Effect's incoming lists with poison at proven-dead structural
    // positions so the PHI keeps verifier-correct arity.
    void appendFullPhiInputs(jeandle::CreatePHIEffect &Effect,
                             ArrayRef<Value *> LiveValues, Type *PhiType) const;
  };

  // Returns a stable PHI for the given (in-loop merge block, ID, offset)
  // tuple, creating one (and registering it in OwnedLoopFieldPhis) on first
  // use. Falls back to createUnparentedPhi when BB is not inside any loop
  // (LI.getLoopFor(BB) == nullptr). Inside a loop — including non-header
  // in-loop merge blocks — the PHI must be cached so any B seed or fresh body
  // exit that names it stays valid while restoreLoopSnapshot truncates
  // OwnedPhis.
  PHINode *getOrCreateLoopFieldPhi(BasicBlock *BB, jeandle::ObjectID ID,
                                   int64_t Offset, Type *Ty, unsigned N,
                                   const Twine &Name);

  // Analyze one basic block: classify its entry (live / dead / deferred),
  // rebuild the per-block state from its predecessors (inherit or merge),
  // then walk its instructions and publish the exit snapshot.
  void processBlock(BasicBlock *BB);
  // The tail of processBlock (also shared by processSeededLoopHeader): walk
  // BB's instructions over the already-built entry state, split the
  // invoke-unwind state, and publish BlockExits[BB].
  void processBlockBodyAndPublish(BasicBlock *BB);
  // Process a loop header block under an explicit seed state (the B or B'
  // seed) instead of merging its structural predecessors.
  void processSeededLoopHeader(BasicBlock *Header,
                               const BlockExitData &HeaderSeed);
  // Seed the loop-header pointer PHI aliases from the preheader edge alone:
  // a PHI whose preheader incoming resolves to an eligible virtual object is
  // pre-aliased to it so the first body pass can fold through the PHI before
  // any backedge state exists.
  void initializeLoopHeaderPhiAliases(BasicBlock *Header,
                                      BasicBlock *Preheader);
  // Drain a block's deferred merge-PHI effects (PendingMergePhis[BB]) into
  // Result.BlockEffects[BB], assigning each a fresh SeqNo at drain time so
  // the transform's SeqNo order is per-pred Materialize, CreatePHI, then
  // body effects. Shared by processBlock and processLoop's post-body merges.
  void drainPendingMergePhis(BasicBlock *BB);
  // Dispatch one instruction: allocations, loads/stores, JavaOps, known
  // intrinsics, icmps, and alias-forwarding each get a dedicated handler;
  // anything else with a virtual operand is an escape point.
  void processInstruction(Instruction *I);

  // Per-block state helpers.
  // Clear CurrentState and the analyzer-wide per-object maps; called at the
  // top of every block before inheriting or merging predecessor state.
  void resetPerBlockState();
  // Copy one predecessor's exit snapshot into the live per-block state
  // (the single-live-pred fast path), skipping ineligible objects
  // (FieldDefinitions excepted — see the definition).
  void inheritFromExit(const BlockExitData &Exit);
  // Merge all of BB's predecessor exit snapshots into the live per-block
  // state by running MergeProcessor (intersection, merge fixpoint, and PHI
  // processing).
  void mergeStates(BasicBlock *BB);
  // Publish the live per-block state as BlockExits[BB].
  void snapshotExitState(BasicBlock *BB);
  // Close Data's virtual-reference invariant: rewrite every
  // FieldValue::virtualRef whose target is no longer virtual in Data to a
  // materialized reference, rejecting objects whose identity cannot be
  // recovered (fresh retry) and cascading to holders that cannot stay
  // virtual.
  void normalizeIneligibleVirtualRefs(BlockExitData &Data);
  // Mirror of snapshotExitState that writes the per-object snapshot into
  // an arbitrary BlockExitData (rather than into BlockExits[BB]). Used by
  // processBlock to capture the pre-invoke state for the unwind variant.
  void snapshotExitStateInto(BlockExitData &Data);
  // Out receives this block's deferred CreatePHI effects. For the entry /
  // single-pred paths it is PendingMergePhis[BB] (drained before the body
  // walk); for a merge it is the MergeProcessor's retry-cleared
  // MergeEffects buffer (committed to PendingMergePhis[BB] after the fixpoint
  // converges) — keeping the merge's speculative CreatePHI effects separate
  // from the block effects committed only once the merge stabilizes.
  void processBlockPhis(BasicBlock *BB, jeandle::EffectList &Out);
  // Truncate Result.OwnedPhis / OwnedInsts to the given marks, deleting any
  // unparented PHIs/insts added since (the MergeProcessor retry discards a
  // failed iteration's fresh non-loop-header PHIs). OwnedLoopFieldPhis
  // (loop-header-cached) is intentionally untouched.
  void deleteOwnedSince(size_t PhiMark, size_t InstMark);

  // Resolve one predecessor-to-successor contribution. Unseen means the
  // predecessor has not published an exit yet, Dead means this exact target
  // edge (or the entire predecessor block) is proven unreachable, and Live
  // carries the normal/unwind snapshot appropriate for this successor.
  EdgeContribution contributionFor(BasicBlock *Pred, BasicBlock *Succ);
  // If the branch/switch Terminator's condition folds to a constant through
  // the scalar-alias chain, report whether Succ is the selected successor.
  // Returns nullopt when the condition is not a foldable branch/switch
  // condition (or its proof is suppressed). A non-literal fold that kills an
  // edge is ledgered as a CFGDeadnessProof.
  std::optional<bool> foldedTerminatorEdgeIsLive(Instruction *Terminator,
                                                 BasicBlock *Succ);
  // Ledger one CFG deadness proof for this attempt, deduplicated by Killer so
  // repeated successor queries for the same terminator record one proof.
  void recordCFGDeadnessProof(CFGDeadnessProofKind Kind, Instruction *Killer,
                              Value *Condition = nullptr,
                              BasicBlock *ChosenSuccessor = nullptr);

  // Has an incoming-edge/block-end materialize already been emitted for
  // (Pred, M, ID)?
  // Used by processBlockPhis Case-A to skip a duplicate mat when the VO was
  // already per-pred-mat'd for THIS merge. The target-local exit view records
  // the flip without changing the shared predecessor state. M=null queries the
  // block-end-drain slot.
  bool isMaterializedAtPred(BasicBlock *Pred, BasicBlock *M,
                            jeandle::ObjectID ID);

  // PHI Case C: synthesize a merged VirtualObject when every incoming of a
  // pointer-PHI resolves to a DIFFERENT but COMPATIBLE virtual ID. Returns
  // true on success (the new VO is registered, the PHI is aliased to it, and
  // per-entry CreatePHI effects are emitted); false if compatibility,
  // identity, or per-entry type checks fail — caller falls through to the
  // Case A per-pred materialize path. Restricted to non-self-reference,
  // non-byte-array, non-two-slot entry cases.
  bool synthesizeCaseC(BasicBlock *BB, PHINode *Phi,
                       ArrayRef<std::optional<jeandle::ObjectID>> InIDs,
                       const SmallBitVector &Dead, jeandle::EffectList &Out);

  // Case C may collapse different allocation identities only when the
  // selected source identity cannot reach an observing consumer. Follow
  // LLVM pointer wrappers transitively; ordinary merge values are observing
  // boundaries, while access paths ending at planned scalar-replacement
  // effects are internal to the virtual object.
  bool hasObservableIdentityUse(jeandle::ObjectID ID, PHINode *CaseCPhi,
                                ArrayRef<BlockExitData *> ExitInfos,
                                ArrayRef<jeandle::ObjectID> CaseCSourceIDs);

  // In-loop Case-C synthetic VO cache, keyed by the merge PHI. The cache
  // exists so an iterative merge stabilization re-visiting an in-loop merge
  // block doesn't synthesize a fresh VO every iteration (otherwise
  // VirtualObjects grows unboundedly and the fixpoint never closes). Cache
  // value is the synthesized VO id; the caller looks it up and reuses the
  // existing VO + alias rather than calling createVirtualObject, REFRESHING
  // the source set on every hit.
  //
  // Under processLoop's body fixpoint the cache hits on iter >= 1: it
  // survives across iterations (not snapshotted by take/restoreLoopSnapshot)
  // so the same synthetic VO ID is reused for the same PHI even as its
  // source set evolves (loop-carried conditional replacement: the join's
  // synthetic becomes the header merge's source on the next pass). Combined
  // with LoopFieldPhiCache (stable per-offset PHI shells), this keeps
  // FieldStates structurally equal across iterations, which the single-state
  // B-vs-B' convergence check requires. Keying by the PHI (not by the
  // source-ID set) is what lets the source set evolve without minting a
  // fresh ObjectID every pass; two different PHIs at the same block still
  // get distinct synthetics. The same map doubles as the memo that lets a
  // later body pass re-resolve a loop-header PHI's back-edge incoming to
  // the previous pass's synthetic (see processBlockPhis).
  DenseMap<PHINode *, jeandle::ObjectID> CaseCVOCache;

  // Create an unparented PHI shell owned by Result.OwnedPhis; the transform
  // inserts it and wires its incomings when the CreatePHI effect applies.
  PHINode *createUnparentedPhi(Type *Ty, unsigned N, const Twine &Name);

  // Produce a Value* of type LoadTy semantically equal to V, possibly
  // synthesizing an unparented coercion instruction (registered with
  // Result.OwnedInsts) that the transform's ReplaceLoad handler will splice
  // in immediately before the load. Returns V unchanged if no coercion is
  // needed, or nullptr if no safe coercion exists; callers should bail to
  // ineligible in the latter case. InsertContext is the load whose DebugLoc
  // (if any) is propagated onto the synthesized cast.
  //
  // Precondition: the load reads a WHOLE stored slot. The caller (processLoad)
  // bails to materialization for any sub-slot / partial-field read before
  // calling, so this routine only handles same-slot type reinterprets.
  Value *coerceToType(Value *V, Type *LoadTy, Instruction *InsertContext);

  // Widen a sub-int scalar (i1/i8/i16) bound for a deopt descriptor field to
  // i32. The field's wire encoding is T_INT (see LLVM2JavaComputational: Java
  // boolean/byte/char/short fields all occupy int slots), and the HotSpot
  // stackmap parser resolves every T_INT location as a 4-byte slot. A sub-int
  // LLVM value would land in a sub-int stackmap location whose bytes the
  // parser cannot read as a T_INT slot (Location::new_stk_loc truncates the
  // byte offset to a 4-byte slot boundary), silently reconstructing the field
  // from unrelated bytes. Widen the value in the IR instead: the stackmap
  // then records an int-width location the parser reads correctly. Constants
  // are already full-width in the stackmap constant pool and need no zext.
  // The zext is registered unparented with Result.OwnedInsts; the transform
  // splices it in immediately before the safepoint.
  Value *widenDeoptScalar(Value *V, Instruction *InsertContext);

  // Why a materialization was emitted. Used to bump the per-reason Statistic
  // counter at the emission site. ALL six reasons (Unhandled, Merge,
  // LoopExit, Phi, Cascade, Nested) have standalone counters; Cascade and
  // Nested additionally roll into JeandlePEAMaterializedUnhandled since they
  // are byproducts of an upstream Unhandled escape (see bumpMaterializeStat).
  enum class MatReason : uint8_t {
    Unhandled, // unhandled escape-point instruction (generic
               // "virtualize returned false" path).
    Merge,     // state merge: mixed virtual/materialized at a multi-pred
               // entry, or lock-count cascade at merge.
    LoopExit,  // force-drain at a loop preheader.
    Phi,       // Case-A LLVM PHI fallback or Case-C synthetic-VO cascade.
    Cascade,   // sibling-virtual cascade triggered by strict lock order.
    Nested,    // recursive prerequisite materialization for an inner VO.
  };

  // Loop-soundness helpers.
  // Runs the preheader-drain ONLY on loops absent from
  // VisitedLoops (those never reached by processLoop). All other loops
  // are handled by processLoop directly: convergence (no drain needed),
  // pessimistic fallback (already drained inline), or
  // the overflow-recovery path which calls processStateBeforeLoopOnOverflow.
  void materializePreheaderVirtualsForUnvisitedLoops();

  // Drain every still-virtual VO at the loop preheader's
  // terminator. Used by the overflow-recovery path to forcibly demote any
  // outer VO that an inner MaterializeAll iteration tried to touch, so
  // the outer fixpoint can re-run cleanly. Idempotent; safe to call
  // multiple times.
  void processStateBeforeLoopOnOverflow(Loop *L);

  // EdgeLocal=true selects merge incoming-edge semantics: the materialize
  // flips only the target-local ExitInfo view, is deduplicated per
  // (PH, TargetMerge, ID), and retains Source->Target provenance for
  // transform-time edge normalization. OrigAlloc remains the materialized SSA
  // value; only replay side effects require edge-local control dependence.
  void materializeAtPredFromExitInfo(jeandle::ObjectID ID, BasicBlock *PH,
                                     BlockExitData &ExitInfo,
                                     bool EdgeLocal = false,
                                     MatReason Reason = MatReason::Merge,
                                     BasicBlock *TargetMerge = nullptr);

  // Prepare a Case-C identity without targeting its borrowed AllocationCall.
  // A complete read-only DAG preflight precedes the monotonic commit: each
  // synthetic PHI is recorded as a valid real replay receiver and every
  // ordinary leaf allocation is retained at its original allocation site.
  // Fields and locks are replayed only by the current MaterializeContext.
  bool prepareSyntheticDAG(jeandle::ObjectID ID);
  // The read-only preflight: ID's synthetic DAG is preparable iff every
  // synthetic node has a well-formed PHI (parented, one incoming per source
  // ID) and every ordinary leaf is eligible. Visiting/Planned/Leaves
  // accumulate the recursion state across the DAG walk.
  bool canPrepareSyntheticDAG(jeandle::ObjectID ID,
                              DenseSet<jeandle::ObjectID> &Visiting,
                              DenseSet<jeandle::ObjectID> &Planned,
                              DenseSet<jeandle::ObjectID> &Leaves);
  // The monotonic commit: record every synthetic node in the DAG as prepared
  // (replay receiver valid, classification erased) bottom-up. Committing is
  // the cycle-defense stack.
  void commitPreparedSyntheticDAG(jeandle::ObjectID ID,
                                  DenseSet<jeandle::ObjectID> &Committing);
  // Whether a replay on the PH -> TargetMerge edge is expressible: the edge
  // must exist, and either PH has a single distinct successor or the edge
  // can be split (no callbr/indirectbr).
  bool isReplayEdgeSupported(BasicBlock *PH, BasicBlock *TargetMerge) const;
  // Observe (transitively) the field definitions of every synthetic source
  // of ID so their stores survive if a source becomes ineligible.
  void observeSyntheticSourceDefinitions(jeandle::ObjectID ID,
                                         DenseSet<jeandle::ObjectID> &Visited);

  // Real loop fixpoint. processLoop runs the fixpoint over L (which
  // includes its sub-loops; nested loops are dispatched recursively when
  // their header is encountered in the RPO walk). On convergence, all blocks
  // of L have their BlockExits populated and the outer RPO walk continues.
  // On failure, restores to the pre-loop snapshot, then runs the pessimistic
  // recovery: force-materialize at preheader (drains every virtual)
  // and process the body once in MaterializeAll mode (every new VO is
  // materialized at its block's end, so nothing stays virtual inside).
  void processLoop(Loop *L, ArrayRef<BasicBlock *> FunctionRPO);

  // Helpers used exclusively by processLoop.
  // Loop blocks of L (including its sub-loops) in function-RPO order,
  // computed once per processLoop and reused across the inner fixpoint body
  // passes (the loop's CFG is stable across the fixpoint).
  SmallVector<BasicBlock *, 32>
  loopBlocksInRPO(Loop *L, ArrayRef<BasicBlock *> FunctionRPO);
  // One body pass of the inner fixpoint: process every block of L in LoopRPO
  // order (recursing into sub-loops), seeding the header with HeaderSeed
  // when given. Publishes ActiveBodyPassLoop/BodyPassProcessed for the
  // duration so processBlockPhis can recognize a not-yet-processed backedge.
  void processLoopBodyOnePass(Loop *L, ArrayRef<BasicBlock *> LoopRPO,
                              ArrayRef<BasicBlock *> FunctionRPO,
                              const BlockExitData *HeaderSeed = nullptr);

  // How much of a LoopSnapshot restoreLoopSnapshot rewinds: Iteration
  // restores only the loop blocks' traversal-local state for an ordinary
  // B/B' retry; Full additionally restores the preheader for the
  // MaterializeAll recovery.
  enum class LoopRestoreMode : uint8_t { Iteration, Full };

  // The pre-loop snapshot. Ordinary B/B' retries restore traversal-local
  // state and effects before reprocessing from the complete B seed. A Full
  // retry restores the same members before abandoning B' and reprocessing the
  // whole loop nest in MaterializeAll mode.
  struct LoopSnapshot {
    BasicBlock *Preheader = nullptr;
    jeandle::PEABlockState CurrentState;
    jeandle::AliasMap Aliases;
    DenseMap<jeandle::ObjectID, DenseMap<int64_t, jeandle::FieldValue>>
        FieldStates;
    FieldDefinitionMap FieldDefinitions;
    DenseSet<StoreInst *> ObservedFieldStores;
    DenseMap<StoreInst *, jeandle::ObjectID> VirtualRefStoreTargets;
    DenseMap<jeandle::ObjectID, unsigned> LockCounts;
    DenseMap<jeandle::ObjectID, SmallVector<LockEnter, 4>> LiveLockEnters;
    DenseSet<jeandle::ObjectID> Materialized;
    DenseMap<jeandle::ObjectID, bool> EligibleSnapshot;
    // Number of VOs that existed before the loop. Restoring the old
    // eligibility map drops entries for allocation-site cache records created
    // by the abandoned traversal, so those records must be re-primed.
    size_t PreIterVOCount = 0;
    // Marks into Result.OwnedPhis / OwnedInsts: values created past the mark
    // belong to the abandoned traversal and are truncated on restore.
    // OwnedLoopFieldPhis is intentionally not marked (its shells must survive
    // rollback so FieldStates stay comparable across iterations).
    size_t OwnedPhisSize = 0;
    size_t OwnedInstsSize = 0;
    // Marks into CFGDeadnessProofs and the Result.NeedsCFGCleanup flag, so a
    // restore forgets proofs recorded by the abandoned traversal.
    size_t CFGDeadnessProofCount = 0;
    bool NeedsCFGCleanup = false;

    // For each block in L and for L's canonical preheader, the prior
    // BlockEffects[BB] (if any) and MaterializedAtPred[BB] (if any), captured
    // before the loop attempt. Iteration restore consumes only the loop-block
    // entries; Full restore also consumes the preheader entry. BlockExits are
    // traversal-local payloads: processLoop erases the current loop nest
    // before every pass and supplies the header state explicitly.
    DenseMap<BasicBlock *, jeandle::EffectList> SavedBlockEffects;
    DenseMap<BasicBlock *, DenseMap<BasicBlock *, DenseSet<jeandle::ObjectID>>>
        SavedMaterializedAtPred;
    DenseSet<BasicBlock *> HadBlockEffects;
    DenseSet<BasicBlock *> HadMaterializedAtPred;
  };

  // Capture / rewind the traversal-local state around a loop fixpoint
  // attempt (see LoopSnapshot). PreservedSeed is a caller-owned seed whose
  // referenced values must survive the OwnedPhis/OwnedInsts truncation.
  void takeLoopSnapshot(Loop *L,
                        const llvm::SmallPtrSetImpl<BasicBlock *> &LoopBlocks,
                        LoopSnapshot &S);
  void
  restoreLoopSnapshot(const llvm::SmallPtrSetImpl<BasicBlock *> &LoopBlocks,
                      const LoopSnapshot &S, LoopRestoreMode Mode,
                      const BlockExitData *PreservedSeed = nullptr);
#ifndef NDEBUG
  // Assert that no FieldValue in Seed references an OwnedPhi/OwnedInst that
  // the iteration restore's truncation would delete.
  void assertPreservedLoopSeedDoesNotReferenceTruncatedOwnedValues(
      const BlockExitData &Seed, const LoopSnapshot &S) const;
#endif

  // Active loop-body-pass context (processLoopBodyOnePass): the loop being
  // re-processed and the blocks already processed in this pass. Consulted by
  // processBlockPhis during an ordinary (unseeded) traversal to distinguish a
  // loop-header PHI's not-yet-processed back-edge predecessor from a genuinely
  // non-virtual incoming. Saved and restored around nested processLoop
  // recursion; null when no body pass is active.
  Loop *ActiveBodyPassLoop = nullptr;
  llvm::SmallPtrSet<BasicBlock *, 16> BodyPassProcessed;

  // Structural equivalence of the BlockExitData base (the per-object
  // book-keeping). Backs the loop fixpoint's single-state B-vs-B'
  // convergence test; FieldValue::shallowEquals compares the per-field
  // entries.
  static bool exitDataEquivalent(const BlockExitData &A,
                                 const BlockExitData &B);

  // Virtualize one jeandle.new_instance / jeandle.new_array invoke: register
  // a fresh VO (reusing the AllocSiteToVO cache inside loop fixpoints),
  // alias the result to it, and record the EliminateAllocation effect.
  // Gating keeps the allocation real instead when its site is suppressed, it
  // sits in an unsafe cyclic block, the VM forbids virtualization, or the
  // mode refuses new virtualizations; MaterializeAll additionally schedules
  // an end-of-block materialization for the new VO.
  void processAllocation(CallBase *CB);
  // Returns true iff the store was consumed as a virtualized store
  // (pointer side resolved to a virtual base, regardless of whether the
  // value side made the VO ineligible). Returns false when the pointer
  // operand is NOT a virtual ref; the caller then falls through to the
  // generic hasVirtualInputs / materializeAllVirtualOperands path so a
  // VALUE-side virtual is not silently leaked to a global / non-virtual
  // pointer (e.g. `store ptr %virt, ptr @G`).
  bool processStore(StoreInst *SI);
  // Fold a load from a virtual object's FieldStates (resolving the pointer
  // via resolveAccess and coercing the value via coerceToType), observing
  // the reaching store definitions. A non-virtual base needs no work (the
  // load stays real); an unreadable shape materializes the base at the load
  // so the real load survives.
  void processLoad(LoadInst *LI);
  // Resolve a load/store pointer to a byte offset within the virtual object
  // BaseID, applying the array-element GEP fast path, the general
  // constant-offset resolver, and the header-offset guard (instance AND
  // array). Returns nullopt (caller marks BaseID ineligible) when the access
  // cannot be virtualized: symbolic array index, non-constant GEP offset,
  // out-of-bounds index, or a header (mark/klass) field access. Shared by
  // every virtualized load/store path: instance-field and array-element
  // accesses alike reduce to one constant byte offset into the object.
  std::optional<int64_t> resolveAccess(Value *Ptr, jeandle::ObjectID BaseID);
  // Frontend-invariant check (JeandlePEAVerifyHeaderAccess): a load/store on
  // a virtual receiver whose constant byte offset is below
  // instanceOopDesc.base_offset_in_bytes is a raw object-header access that
  // should have lived inside a lower-phase >= 1 JavaOp (which PEA folds by
  // name). Called from the resolveAccess bail paths, where the access is
  // about to force conservative materialization of its virtual base — the
  // only places PEA is actually harmed. Offsets that merely fail resolution
  // (symbolic index, non-constant GEP) do not report. Only INSTANCE virtuals
  // are checked: on array virtuals a sub-base constant byte offset can
  // legitimately arise from a constant negative array index (the abstract
  // interpreter's typed-element GEP shape, e.g. a[-1] on a scale-8 array
  // resolves to ArrayBaseOffset-8), which resolveAccess already rejects at
  // the array-element fast path as a designed out-of-bounds case — firing
  // there would be a false positive on legal bytecode.
  void checkRawHeaderAccess(const Instruction *I, Value *Ptr,
                            jeandle::ObjectID BaseID);
  // TODO(unsafe-inliner): processAtomicRMW / processCmpXchg (re-add with the
  // jeandle-jdk frontend inliner for Unsafe atomic intrinsics),
  // processArrayCopy (System.arraycopy → llvm.memcpy/memmove), processMemSet
  // (Arrays.fill → llvm.memset). Until then these shapes fall through to
  // conservative materialization.
  // Dispatch one jeandle JavaOp call to its fold handler below. Returns true
  // iff the op was folded; an unrecognized op returns false so the caller
  // takes the generic escape path.
  bool processJavaOp(CallBase *CB);
  // Known non-escaping LLVM intrinsics (assume, lifetime/invariant
  // markers, debug, annotations, branch hints, ...) are no-ops for PEA;
  // launder/strip.invariant.group forward the argument's virtual alias.
  // Returns true if the intrinsic was handled (no-op or alias-forwarded),
  // false to fall through to the ICmp/JavaOp/generic-escape path.
  bool processIntrinsic(llvm::IntrinsicInst *II);
  // Fold an equality icmp against a virtual pointer to a constant (virtuals
  // are non-null by construction; identity comparison). Returns true if
  // folded, false to fall through to materialization.
  bool foldICmpEquality(llvm::ICmpInst *ICmp);
  // Fold handlers for the individual jeandle JavaOps on virtual receivers:
  // each folds its op to a constant / alias / elision and returns true, or
  // returns false so the op falls through to materialization of its virtual
  // operands.
  bool foldArrayLength(CallBase *CB);
  bool foldLoadKlass(CallBase *CB);
  bool foldGetClass(CallBase *CB);
  bool foldCheckCast(CallBase *CB);
  bool foldInstanceOf(CallBase *CB);
  // Fold a monitorenter on an eligible virtual receiver into lock-state
  // tracking and a ReplaceCall elision. Returns false otherwise; an
  // ineligible (already-abandoned) receiver first cascades still-locked
  // shallower virtuals (strict lock order) because the enter survives as a
  // real lock.
  bool foldMonitorEnter(CallBase *CB);
  // Fold a monitorexit matching a folded enter (pops the lock stack and
  // elides the call); an unmatched or non-virtual exit falls through.
  bool foldMonitorExit(CallBase *CB);
  // Resolve the CFG-derived absolute lock depth of a monitorenter call site.
  // An invalid model or a site absent from the reachable CFG has no depth.
  std::optional<uint32_t> getLockDepth(CallBase *CB) const;
  // Strict-lock-order cascade at a surviving monitorenter: before a REAL
  // (non-virtualized) monitorenter whose depth is D, materialize every
  // still-virtual VO holding an elided lock with a strictly shallower min
  // depth, so the re-emitted lock replay batch cannot be ordered after this
  // real enter. Fired from processInstruction on the not-deleted
  // monitorenter branch, distinct from foldMonitorEnter's elide-path
  // pre-cascade.
  void materializeVirtualLocksBefore(CallBase *MonEnter);
  // Fold handlers for the VM-runtime JavaOps: array-store type check, card
  // barrier, value-based-class check, and finalizer registration. Each
  // returns true iff the op was folded or elided for a virtual receiver.
  bool foldArrayStoreCheck(CallBase *CB);
  bool foldPostBarrier(CallBase *CB);
  bool foldCheckIfValueBased(CallBase *CB);
  bool foldRegisterFinalizerIfNeeded(CallBase *CB);
  // Common helper for checkcast/check_instanceof: returns the folded constant
  // bool (true/false) if the relationship is statically known, or
  // std::nullopt otherwise.
  std::optional<bool> evalSubtypeRelation(uintptr_t SubKlass,
                                          uintptr_t SuperKlass);
  // Record a ReplaceCall effect substituting CB with Replacement (constant
  // or alias); ID owns the mutation for eligibility filtering.
  void emitReplaceCall(CallBase *CB, Value *Replacement, jeandle::ObjectID ID);
  // PEA deopt support. Parse the complete safepoint bundle, combine durable
  // legacy descriptors with current virtual-object state, and publish one
  // immutable whole-pool rewrite. The pure planner owns reachability, pruning,
  // and dense wire-ID assignment. Reachable current nodes that cannot be
  // described are materialized and the complete pool is planned again, so a
  // parent may remain virtual with a real-oop scalar field. Only exact source
  // cells rewritten to VORefs or removed by legacy pruning enter the handled
  // operand set; all other scalar uses retain ordinary escape semantics.
  // A virtual object referenced only by a deopt bundle gets a virtual mapping
  // in the pool instead of escaping: the deopt-state reference itself is not
  // an escape point.
  void recordDeoptBundleMappings(CallBase *CB);
  // Materialize only virtual operands of CB's deopt bundle that were not
  // described by recordDeoptBundleMappings. Handled intrinsics use this
  // deopt-specific fallback so their ordinary arguments and informational
  // operand bundles remain non-escaping.
  void materializeUnhandledDeoptBundleOperands(CallBase *CB);
  // True iff \p U is an input of I's "deopt" operand bundle whose resolved
  // ObjectID was recorded as a scoped virtual mapping at this instruction
  // covered by the current whole-pool plan. Used by the generic escape path to
  // skip deopt-state operands.
  bool isHandledDeoptBundleOperand(const Use &U, Instruction *I);
  // Single source of truth for "which distinct virtual ObjectIDs does I use as
  // operands (skipping described deopt-bundle operands)?" The generic escape
  // path (materializeAllVirtualOperands) enumerates this set. Returns IDs
  // sorted for deterministic effect order.
  void collectDistinctVirtualOperands(Instruction *I,
                                      SmallVectorImpl<jeandle::ObjectID> &Out);
  // The generic escape path: materialize every distinct virtual operand of I
  // at I (skipping described deopt-bundle operands).
  void materializeAllVirtualOperands(Instruction *I);
#ifndef NDEBUG
  // Debug-only reachability check backing the invariant assert in
  // materializeOperandsAtStore. Returns true if V's pointer-derivation def
  // chain (the same wrapper set resolveVirtualRef peels: GEP/BitCast/
  // AddrSpaceCast/Freeze/PtrToInt/IntToPtr/PHI/Select) reaches a value that is
  // alias-registered as a STILL-VIRTUAL VO. Mirrors resolveVirtualRef but
  // returns a boolean (any arm reaches a live VO) instead of a single agreed
  // identity, and never chases arithmetic (add/sub/...) — those cases are
  // guarded upstream by the generic-escape materialization at PtrToInt
  // (regression test
  // llvm/test/Jeandle/partial-escape/resolve_cap_02_opaque_inttoptr_escape.ll).
  // See materializeOperandsAtStore.
  bool debugReferencesLiveVirtualObject(Value *V);
#endif
  // Materialize every virtual NON-BUNDLE call argument of CB before the
  // call, per argument. Runs BEFORE recordDeoptBundleMappings, so a VO that
  // is both a real argument AND a deopt-bundle operand of the same call is
  // materialized at the call and its bundle slot keeps the live OrigAlloc —
  // one Java object keeps one identity across a during-call deopt.
  // Arg-scoped: bundle operands are NOT consulted (they are deopt frame
  // state, handled by recordDeoptBundleMappings).
  void materializeVirtualCallArgs(CallBase *CB);
  // The escape-point materialization path: materialize ID immediately before
  // InsertBefore in the live per-block state, cascading to nested virtual
  // fields and still-locked virtuals as required.
  void materializeAt(jeandle::ObjectID ID, Instruction *InsertBefore,
                     MatReason Reason = MatReason::Unhandled);

  // One materialization request, viewed uniformly by ensureMaterialized.
  // Because Jeandle's per-block state is fragmented across several maps (see
  // STATE MODEL above), the unified algorithm is parameterized on this view:
  // the operative state maps (the live analyzer maps for the escape-point
  // path, or a predecessor's BlockExitData maps for the merge-driven path),
  // the idempotency set, and callbacks for the per-path I/O. The two
  // wrappers (materializeAt / materializeAtPredFromExitInfo) each build a
  // context and delegate the shared
  // cascade/lock-capture/prereq/dominance/emit/flip algorithm to
  // ensureMaterialized, localizing the genuine per-path differences in the
  // callbacks instead of scattering `if (isPredPath)` through the body.
  struct MaterializeContext {
    // The operative per-object state maps: the live analyzer maps on the
    // escape-point path, or one predecessor's BlockExitData maps on the
    // merge-driven path.
    DenseMap<jeandle::ObjectID, DenseMap<int64_t, jeandle::FieldValue>>
        &FieldStates;
    FieldDefinitionMap &FieldDefinitions;
    DenseMap<jeandle::ObjectID, unsigned> &LockCounts;
    DenseMap<jeandle::ObjectID, SmallVector<LockEnter, 4>> &LiveLockEnters;
    // Idempotency set: has this ObjectID already been materialized in this call
    // chain (cascade cycle-prevention) AND function-wide for this path? Bound
    // to the analyzer-wide `Materialized` (escape-point path) or to
    // `MaterializedAtPred[PH][TargetMerge]` (merge-driven path — a DenseSet<ID>
    // per (PH, target-merge) so distinct target merges each get their own
    // per-pred mat at the same PH, while a block-end M=null drain dedups at
    // that program point).
    DenseSet<jeandle::ObjectID> &MaterializedSet;
    // Why this materialization was emitted; bumped into the per-reason
    // Statistic counters (see bumpMaterializeStat).
    MatReason Reason;
    // Provenance retained through final replay-plan construction. Alternative
    // predecessor plans for one merge share LogicalEscape but retain distinct
    // ReplaySource blocks; ReplayTarget is the merge block an edge-local
    // replay is confined to (null for a plain insertion-point replay).
    Value *LogicalEscape;
    BasicBlock *ReplaySource;
    BasicBlock *ReplayTarget;
    // Recurse on a nested/cascade object (materializeAt vs
    // materializeAtPredFromExitInfo — different signatures, hence a callback).
    function_ref<void(jeandle::ObjectID, MatReason)> Recurse;
    // Clear the operative lock state after the surviving unbalanced enters are
    // captured for re-emit. Live also clears the ObjectState::Locks mirror;
    // pred clears the ExitInfo maps. Needed so commit()'s LockCounts!=0 gate
    // doesn't disqualify the VO.
    function_ref<void(jeandle::ObjectID)> ClearLockState;
    // Capture the surviving unbalanced enters into the Materialize effect's
    // Locks list (sorted ascending by BytecodeDepth); applyMaterialize
    // re-emits them as real monitorenter calls at the materialize point (the
    // lock replay batch).
    function_ref<void(ArrayRef<LockEnter>, jeandle::ObjectID,
                      jeandle::MaterializeEffect &E)>
        CaptureLocksIntoEffect;
    // Compute the safe materialization insertion point.
    function_ref<Instruction *()> ComputeSafeIP;
    // Flip the per-object state to materialized (live CurrentState vs
    // ExitInfo).
    function_ref<void(jeandle::ObjectID)> FlipState;
  };
  // Shared materialization driver: run the
  // cascade/lock-capture/prereq/dominance/emit/flip algorithm for ID under
  // context C (see MaterializeContext).
  void ensureMaterialized(jeandle::ObjectID ID, MaterializeContext &C);
  // Mark the reaching definitions of ID's field at Offset observed (a folded
  // load, materialization, deopt snapshot, or fallback read them), so their
  // stores survive if ID later becomes ineligible.
  void observeFieldDefinition(jeandle::ObjectID ID, int64_t Offset,
                              const FieldDefinitionMap &Definitions);
  // Mark every reaching definition of ID observed; used when ID's complete
  // state may be read (materialization, deopt snapshot).
  void observeFieldDefinitions(jeandle::ObjectID ID,
                               const FieldDefinitionMap &Definitions);
  // Observing a live VirtualRef store exposes the referenced object's complete
  // state at the same program point. The per-call set bounds cycles without
  // suppressing a later observation that carries newer reaching definitions.
  void observeAllFieldDefinitions(jeandle::ObjectID ID,
                                  const FieldDefinitionMap &Definitions,
                                  DenseSet<jeandle::ObjectID> &FullyObserved);
  // Whether a field/entry value can be produced at a program point (used by
  // ensureMaterialized's materialization gate and by the deopt-bundle
  // descriptor's release-build correctness gate).
  bool isValueAvailableAt(Value *Root, Instruction *IP,
                          BasicBlock *ReplaySource = nullptr,
                          BasicBlock *ReplayTarget = nullptr);
  // Forward a virtual alias through a pointer-identity-preserving
  // instruction (GEP/cast/freeze/select) whose operand carries one;
  // unresolvable operand shapes take the generic escape path.
  void propagatePointerAlias(Instruction *I);

  // Walk every other VO's FieldStates in the supplied map and rewrite
  // any FieldValue::virtualRef(FlippedID) entry to MaterializedRef(NewPtr).
  // Called after a VO is flipped to Materialized so sibling VOs that hold a
  // reference to it learn about the materialized pointer immediately. Without
  // this sweep, a later store/load through a sibling's field that still
  // carries VirtualRef(FlippedID) would fire the transform-side assertion
  // ("VirtualRef field entries must have been rewritten to MaterializedRef
  // during analysis") in debug, or silently drop the field in release.
  void updateOtherStatesForMaterialized(
      jeandle::ObjectID FlippedID, Value *NewPtr,
      DenseMap<jeandle::ObjectID, DenseMap<int64_t, jeandle::FieldValue>> &FS);

  // Bump the total materialization count and the counter for the supplied
  // reason. Cascade and Nested are also included in the Unhandled rollup.
  void bumpMaterializeStat(MatReason R);

  // Finalize the attempt: drop the effects of ineligible objects, classify
  // every allocation site (NeverEscapes / PartiallyEscapes / AlwaysEscapes),
  // run the commit-time deopt-pool and lock-balance checks, and validate the
  // attempt's obligations. A validation failure records the offending
  // proofs/sites for a suppressed fresh retry instead of patching the plan.
  void commit();
  // True iff E stays meaningful even when its owner is ineligible: an
  // EliminateStore whose store nobody observed is still valid dead-store
  // elimination on a kept-real allocation.
  bool effectSurvivesIneligibleOwner(const jeandle::Effect &E) const;
  // Drop every recorded effect owned by IDs (except the survivors above) and
  // stamp their allocation sites AlwaysEscapes.
  void dropEffectsForIneligible(const DenseSet<jeandle::ObjectID> &IDs);
  // The final disposition of a deopt operand after chasing the replacement
  // chain: a concrete SSA value, a deletion with no replacement, or an oop
  // handle that carries no SSA dependency.
  struct FinalValue {
    enum Kind : uint8_t {
      ResolvedValue,
      Deleted,
      DependencyFreeOopHandle
    } K = ResolvedValue;
    llvm::Value *V = nullptr;
  };
  // Check that every surviving deopt-pool rewrite can still reconstruct its
  // described objects from values available at the safepoint; failures set
  // InvalidDeoptObligation and collect the offending allocation sites.
  void validateFinalDeoptObligations();
  // Re-check every recorded CFG deadness proof against the final effect
  // plan (the folding effect may have been filtered out); returns the
  // killers whose proof no longer holds.
  SmallVector<Instruction *, 8> validateCFGDeadnessProofs() const;
  // Publish a validated attempt's diagnostics: flush the attempt-local
  // statistics to the global counters, emit the effect trace, and dump the
  // optional per-function escape classification.
  void publishAttemptOutputs();

  // Mark a VO ineligible, taking the TRANSITIVE closure over synthetic Case-C
  // sources. A synthetic VO has no real backing allocation (AllocationCall is
  // borrowed), so dropping it alone would let its per-pred sources still be
  // eliminated, leaving the merge PHI's incomings as poison. A source can
  // itself be synthetic (Case C can nest), so the cascade walks the whole
  // synthetic-source DAG so every leaf real allocation survives in IR. The
  // relation is acyclic (a source is created at an earlier merge than the
  // synthetic referencing it), so the worklist terminates; the visited set is
  // pure cycle defense. The SyntheticPhi alias is reset for every synthetic so
  // downstream resolveVirtualRef stops folding through it. Safe on
  // non-synthetic VOs (degenerates to Eligible[ID] = false). Single source of
  // truth for the conservative synthetic cascade used when identity-DAG
  // preparation fails preflight. FreshRetry=true additionally rejects every
  // ordinary allocation leaf in a fresh Analyzer attempt: the current
  // virtualization plan cannot be completed soundly, so it is abandoned and
  // retried with those sites kept real from the start.
  void markIneligible(jeandle::ObjectID ID, bool FreshRetry = false);
  // Collect the ordinary allocation sites backing ID (walking the
  // synthetic-source DAG) into RetryVirtualizationAllocationSites, for a
  // fresh suppressed retry.
  void collectRetryVirtualizationSites(jeandle::ObjectID ID);

  // The real SSA identity of a VO: OrigAlloc for an ordinary object, or the
  // Case-C merge PHI for a synthetic.  The latter applies both to conservative
  // ineligibility and to successful prepared point-local replay.
  Value *realIdentityOf(jeandle::ObjectID ID);
};

void Analyzer::observeFieldDefinition(jeandle::ObjectID ID, int64_t Offset,
                                      const FieldDefinitionMap &Definitions) {
  auto DIt = Definitions.find(ID);
  if (DIt == Definitions.end())
    return;
  auto OIt = DIt->second.find(Offset);
  if (OIt == DIt->second.end())
    return;
  // The root load observes only this cell. A VirtualRef stored in the cell
  // exposes its referenced object, so recursive nodes are observed in full.
  // Do not seed FullyObserved with ID: a cycle back to the root exposes the
  // root object itself and must upgrade it to a full observation.
  DenseSet<jeandle::ObjectID> FullyObserved;
  for (StoreInst *SI : OIt->second) {
    ObservedFieldStores.insert(SI);
    auto RIt = VirtualRefStoreTargets.find(SI);
    if (RIt != VirtualRefStoreTargets.end())
      observeAllFieldDefinitions(RIt->second, Definitions, FullyObserved);
  }
}

void Analyzer::observeFieldDefinitions(jeandle::ObjectID ID,
                                       const FieldDefinitionMap &Definitions) {
  DenseSet<jeandle::ObjectID> FullyObserved;
  observeAllFieldDefinitions(ID, Definitions, FullyObserved);
}

void Analyzer::observeAllFieldDefinitions(
    jeandle::ObjectID ID, const FieldDefinitionMap &Definitions,
    DenseSet<jeandle::ObjectID> &FullyObserved) {
  SmallVector<jeandle::ObjectID, 8> Worklist(1, ID);
  while (!Worklist.empty()) {
    jeandle::ObjectID Current = Worklist.pop_back_val();
    if (!FullyObserved.insert(Current).second)
      continue;
    auto DIt = Definitions.find(Current);
    if (DIt == Definitions.end())
      continue;
    for (const auto &Off : DIt->second)
      for (StoreInst *SI : Off.second) {
        ObservedFieldStores.insert(SI);
        auto RIt = VirtualRefStoreTargets.find(SI);
        if (RIt != VirtualRefStoreTargets.end())
          Worklist.push_back(RIt->second);
      }
  }
}

void Analyzer::collectRetryVirtualizationSites(jeandle::ObjectID ID) {
  SmallVector<jeandle::ObjectID, 8> Worklist(1, ID);
  DenseSet<jeandle::ObjectID> Visited;
  while (!Worklist.empty()) {
    jeandle::ObjectID Cur = Worklist.pop_back_val();
    if (!Visited.insert(Cur).second || Cur == jeandle::InvalidObjectID ||
        Cur >= Result.VirtualObjects.size())
      continue;
    const jeandle::VirtualObject &VObj = *Result.VirtualObjects[Cur];
    if (VObj.IsSynthetic) {
      Worklist.append(VObj.SyntheticSourceIDs.begin(),
                      VObj.SyntheticSourceIDs.end());
      continue;
    }
    auto *Site = dyn_cast_or_null<CallBase>((Value *)VObj.AllocationCall);
    if (Site && !llvm::is_contained(RetryVirtualizationAllocationSites, Site))
      RetryVirtualizationAllocationSites.push_back(Site);
  }
}

void Analyzer::markIneligible(jeandle::ObjectID ID, bool FreshRetry) {
  if (FreshRetry)
    collectRetryVirtualizationSites(ID);
  // Synthetic sources are kept real as a unit. A synthetic without a usable
  // backing allocation cannot survive while its sources are eliminated. The
  // worklist is finite: synthetic sources precede their synthetic owner, and
  // Visited is a defensive cycle guard.
  SmallVector<jeandle::ObjectID, 8> Worklist;
  DenseSet<jeandle::ObjectID> Visited;
  Worklist.push_back(ID);
  while (!Worklist.empty()) {
    jeandle::ObjectID Cur = Worklist.pop_back_val();
    if (!Visited.insert(Cur).second)
      continue;
    observeFieldDefinitions(Cur, FieldDefinitions);
    Eligible[Cur] = false;
    jeandle::VirtualObject &VObj = *Result.VirtualObjects[Cur];
    if (VObj.IsSynthetic) {
      if (VObj.SyntheticPhi)
        Aliases.resetAlias(VObj.SyntheticPhi);
      for (jeandle::ObjectID PID : VObj.SyntheticSourceIDs)
        if (PID != jeandle::InvalidObjectID)
          Worklist.push_back(PID);
    }
  }
}

Value *Analyzer::realIdentityOf(jeandle::ObjectID ID) {
  jeandle::VirtualObject &VObj = *Result.VirtualObjects[ID];
  if (VObj.IsSynthetic)
    return VObj.SyntheticPhi;
  return VObj.AllocationCall;
}

void Analyzer::drainPendingMergePhis(BasicBlock *BB) {
  // Effects that have already been recorded into this block's BlockEffects
  // received their sequence numbers while the merge was stabilized; assign
  // the deferred CreatePHI effects sequence numbers now so the resulting
  // order is per-pred Materialize, CreatePHI, then body effects. A body
  // Materialize can consequently replay a merged field PHI that is already
  // present in the IR.
  auto It = PendingMergePhis.find(BB);
  if (It == PendingMergePhis.end())
    return;
  jeandle::EffectList &Phis = It->second;
  while (!Phis.empty()) {
    std::unique_ptr<jeandle::Effect> Effect = Phis.spliceOut(0);
    Effect->SeqNo = Result.nextSeqNo();
    Result.addBlockEffect(std::move(Effect));
  }
  PendingMergePhis.erase(It);
}

// Analyze one basic block. Entry classification runs first: with no Live
// predecessor contribution the block is either deferred (some pred Unseen —
// a loop fixpoint backfills it) or publishes a dead exit without an
// instruction walk. Otherwise the per-block state is rebuilt from the
// predecessors — inherited from a single live pred, or merged across preds
// (mergeStates also handles the degenerate one-pred case when a Java-heap
// pointer PHI is present, since Case-A may materialize an incoming and force
// a rebuild) — and the body walk plus exit publication run in
// processBlockBodyAndPublish.
void Analyzer::processBlock(BasicBlock *BB) {
  ScopedEdgeExitViews EdgeViews(*this);

  // Classify the block before rebuilding or walking any abstract state. A
  // block with at least one Live predecessor is analyzed from Live inputs
  // only. A block whose every published predecessor contribution is Dead
  // publishes a dead exit without processing its instructions, and a block
  // with no Live input but at least one Unseen input is deferred so a loop
  // fixpoint can backfill it later.
  if (BB != &F.getEntryBlock()) {
    bool HasLive = false;
    bool HasUnseen = false;
    for (BasicBlock *Pred : predecessors(BB)) {
      EdgeContribution Contribution = contributionFor(Pred, BB);
      HasLive |= Contribution.isLive();
      HasUnseen |= Contribution.isUnseen();
    }
    if (!HasLive) {
      resetPerBlockState();
      PendingMergePhis.erase(BB);
      if (HasUnseen) {
        BlockExits.erase(BB);
        return;
      }
      BlockExitInfo DeadExit;
      DeadExit.IsDead = true;
      BlockExits[BB] = std::move(DeadExit);
      return;
    }
  }

  // Rebuild per-block state from the predecessor snapshots before we walk
  // instructions. Entry block starts empty. A single-pred block without a
  // Java-heap pointer PHI can inherit directly; otherwise it runs the merge,
  // including the degenerate one-live-pred and "no processed preds" cases. A
  // Java-heap pointer PHI can materialize its incoming even with one
  // predecessor, so the merge retry must rebuild the inherited state before
  // the block body is analyzed.
  // Statically-unreachable blocks (constant-condition dead arms, blocks
  // unreachable from entry) are pruned by the pre-PEA SimplifyCFG pass in
  // buildJeandlePipeline, so we never see them here.

  resetPerBlockState();
  if (BB == &F.getEntryBlock()) {
    // Entry: nothing to inherit; per-block state is empty.
    processBlockPhis(BB, PendingMergePhis[BB]);
  } else if (BB->hasNPredecessors(1) &&
             llvm::none_of(BB->phis(), [](PHINode &Phi) {
               Type *Ty = Phi.getType();
               return Ty->isPointerTy() &&
                      cast<PointerType>(Ty)->getAddressSpace() ==
                          jeandle::AddrSpace::JavaHeapAddrSpace;
             })) {
    // processBlockPhis only handles Java-heap pointer PHIs, so it cannot emit
    // Case-A materialization on this path and no merge retry is needed.
    BasicBlock *P = *predecessors(BB).begin();
    EdgeContribution Contribution = contributionFor(P, BB);
    assert(Contribution.isLive() &&
           "single-predecessor block passed the live-entry gate");
    inheritFromExit(*Contribution.Data);
    processBlockPhis(BB, PendingMergePhis[BB]);
  } else {
    // mergeStates wraps BOTH the per-VO loop AND the PHI loop in a
    // single do-while so a Case-C synthesis or Case-A fallback in
    // processBlockPhis that materializes an inner VO at a pred can
    // reawaken the per-VO decisions (which depended on the now-stale
    // pred-side virtuality). mergeStates calls processBlockPhis itself.
    mergeStates(BB);
  }

  if (!RetryVirtualizationAllocationSites.empty())
    return;
  processBlockBodyAndPublish(BB);
}

void Analyzer::processSeededLoopHeader(BasicBlock *Header,
                                       const BlockExitData &HeaderSeed) {
  ScopedEdgeExitViews EdgeViews(*this);
  resetPerBlockState();
  inheritFromExit(HeaderSeed);
  processBlockBodyAndPublish(Header);
}

// Seed the loop-header pointer PHI aliases from the preheader edge alone.
// Before the first body pass no backedge predecessor has been processed, so
// a header PHI's full merge cannot run yet; aliasing the PHI to the virtual
// object its preheader incoming resolves to lets the first pass fold through
// the PHI. The loop fixpoint later re-derives the alias from the complete
// predecessor set. Any stale alias from a previous iteration is reset first.
void Analyzer::initializeLoopHeaderPhiAliases(BasicBlock *Header,
                                              BasicBlock *Preheader) {
  ScopedEdgeExitViews EdgeViews(*this);
  EdgeContribution Forward = contributionFor(Preheader, Header);

  jeandle::PEABlockState ForwardState;
  if (Forward.isLive())
    for (jeandle::ObjectID ID : Forward.Data->Virtuals)
      if (Eligible.lookup(ID))
        ForwardState.addObject(ID, jeandle::ObjectState());

  for (PHINode &Phi : Header->phis()) {
    Type *Ty = Phi.getType();
    if (!Ty->isPointerTy() || cast<PointerType>(Ty)->getAddressSpace() !=
                                  jeandle::AddrSpace::JavaHeapAddrSpace)
      continue;

    Aliases.resetAlias(&Phi);
    if (!Forward.isLive())
      continue;

    // Find the unique incoming slot for the preheader edge. If Preheader
    // feeds Header over more than one edge (duplicate PHI entries), skip:
    // the seed alias must come from one unambiguous incoming value.
    int PreheaderIndex = -1;
    for (unsigned I = 0; I < Phi.getNumIncomingValues(); ++I) {
      if (Phi.getIncomingBlock(I) != Preheader)
        continue;
      if (PreheaderIndex != -1) {
        PreheaderIndex = -1;
        break;
      }
      PreheaderIndex = static_cast<int>(I);
    }
    if (PreheaderIndex == -1)
      continue;

    auto Identity = jeandle::pea::resolveVirtualIdentity(
        Phi.getIncomingValue(static_cast<unsigned>(PreheaderIndex)),
        ForwardState, Aliases, DL,
        jeandle::pea::VirtualIdentityMode::WholeObject);
    if (Identity.isDefined() && Eligible.lookup(Identity.getObjectID()))
      Aliases.addVirtualAlias(&Phi, Identity.getObjectID(),
                              /*IsWholeObject=*/true);
  }
}

// Walk BB's instructions over the entry state built by processBlock (or the
// loop-header seed) and publish the exit snapshot. Ordering contract: the
// deferred merge CreatePHI effects drain first so body effects can consume
// the PHIs; VOs registered under MaterializeAll drain at the terminator
// before the snapshot so neither successor inherits a stale virtual view;
// and an invoke terminator splits the exit state — the normal successor
// inherits the post-invoke state while the unwind successor inherits the
// pre-invoke snapshot, patched for every VO materialized immediately before
// the invoke.
void Analyzer::processBlockBodyAndPublish(BasicBlock *BB) {

  // Merge effects precede effects produced while walking the block body, so
  // a body effect can consume the PHIs the merge created.
  drainPendingMergePhis(BB);

  // Exception edge state splitting. If the block ends in an InvokeInst,
  // snapshot the per-object state immediately BEFORE applying the invoke.
  // The post-invoke state (the regular snapshotExitState below) is what
  // the normal successor inherits; the snapshot we take here becomes the
  // unwind successor's inheritance. Materializations inserted before this
  // invoke patch the snapshot after instruction processing because their
  // replay and object exposure execute on both successors.
  //
  // We only bother when the function has a personality (no personality =>
  // no real exception handlers; the work would be observably inert) and
  // the terminator actually IS an InvokeInst. Both conditions are required
  // for state-splitting to matter.
  InvokeInst *TermII = dyn_cast<InvokeInst>(BB->getTerminator());
  bool MaybeSplit = TermII && F.hasPersonalityFn();
  std::optional<BlockExitData> PreInvokeSnapshot;
  // Drain any VOs registered under MaterializeAll in this
  // block, materializing each at the terminator IP. Called immediately
  // before the terminator instruction is processed so the materialize
  // takes effect BEFORE PreInvokeSnapshot (so both normal and unwind
  // successors inherit a Materialized-VO view, never a stale Virtual
  // view that would dangling-ref an OrigAlloc that the transform RAUW'd
  // away). Idempotent (clears the per-block list).
  auto drainMaterializeAll = [&]() {
    auto PMIt = PendingMaterializeAllVOs.find(BB);
    if (PMIt == PendingMaterializeAllVOs.end())
      return;
    SmallVector<jeandle::ObjectID, 4> ToMat = std::move(PMIt->second);
    PendingMaterializeAllVOs.erase(PMIt);
    llvm::sort(ToMat); // deterministic order
    Instruction *IP = BB->getTerminator();
    for (jeandle::ObjectID ID : ToMat)
      materializeAt(ID, IP, MatReason::Unhandled);
  };

  for (Instruction &I : *BB) {
    if (&I == BB->getTerminator())
      drainMaterializeAll();
    if (!RetryVirtualizationAllocationSites.empty())
      return;
    if (MaybeSplit && &I == TermII) {
      PreInvokeSnapshot.emplace();
      snapshotExitStateInto(*PreInvokeSnapshot);
      if (!RetryVirtualizationAllocationSites.empty())
        return;
    }
    processInstruction(&I);
    if (!RetryVirtualizationAllocationSites.empty())
      return;
  }
  // Defensive: empty blocks or blocks whose terminator was never enqueued
  // through the loop above still need a drain (the foreach loop above does
  // the right thing for any non-empty block, but a future change might
  // skip-over the terminator).
  drainMaterializeAll();

  snapshotExitState(BB);
  if (!RetryVirtualizationAllocationSites.empty())
    return;

  if (TermII) {
    BlockExitInfo &Info = BlockExits[BB];
    Info.TerminatorInvoke = TermII;
    Info.UnwindDest = TermII->getUnwindDest();

    // Detect a provisional effect plan that removes this invoke: a folded
    // JavaOp has a ReplaceCall effect, while a virtualized allocation has an
    // EliminateAllocation effect. The latter kills its unwind edge only when
    // final classification is NeverEscapes, so both forms are ledgered and
    // revalidated after eligibility filtering.
    bool FoldedInvoke = false;
    bool EliminatedAllocationInvoke = false;
    auto EIt = Result.BlockEffects.find(BB);
    if (EIt != Result.BlockEffects.end()) {
      for (const auto &E : EIt->second) {
        if (E.getTarget() != TermII)
          continue;
        if (E.getKind() == jeandle::Effect::Kind::ReplaceCall)
          FoldedInvoke = true;
        else if (E.getKind() == jeandle::Effect::Kind::EliminateAllocation)
          EliminatedAllocationInvoke = true;
      }
    }
    bool KillUnwind = (FoldedInvoke || EliminatedAllocationInvoke) &&
                      !SuppressedCFGProofs.count(TermII);
    Info.UnwindEdgeKilled = KillUnwind;
    if (KillUnwind) {
      recordCFGDeadnessProof(
          FoldedInvoke ? CFGDeadnessProofKind::FoldedInvoke
                       : CFGDeadnessProofKind::EliminatedAllocationInvoke,
          TermII);
      Result.NeedsCFGCleanup = true;
    }

    // Patch the pre-invoke snapshot for every VO materialized immediately
    // before this invoke. Field replay, lock re-emission, and exposure of the
    // real object all precede the call on both successors, so the unwind state
    // must not retain pre-call virtual fields or locks. Patching before the
    // equivalence check below can make the whole split unnecessary.
    if (PreInvokeSnapshot) {
      auto EIt = Result.BlockEffects.find(BB);
      if (EIt != Result.BlockEffects.end())
        for (const auto &E : EIt->second) {
          const auto *ME = dyn_cast<jeandle::MaterializeEffect>(&E);
          if (!ME || !ME->hasMutationOwner())
            continue;
          if ((Value *)ME->InsertBefore != (Value *)TermII)
            continue;
          markObjectMaterializedInExitData(
              *PreInvokeSnapshot, ME->getMutationOwner(),
              realIdentityOf(ME->getMutationOwner()));
        }
      normalizeIneligibleVirtualRefs(*PreInvokeSnapshot);
#ifndef NDEBUG
      assertVirtualReferenceClosure(*PreInvokeSnapshot);
#endif
      if (!RetryVirtualizationAllocationSites.empty())
        return;
    }

    // Only stash the pre-invoke snapshot if (a) we actually took one
    // (function has a personality), (b) the unwind edge remains live, AND
    // (c) the snapshot actually differs from the post-invoke base data. The
    // last gate avoids paying the DenseMap-copy cost (and the
    // convergence-check cost downstream) for invokes that triggered no PEA
    // state change.
    if (!KillUnwind && PreInvokeSnapshot &&
        !exitDataEquivalent(Info, *PreInvokeSnapshot))
      Info.UnwindData = std::move(PreInvokeSnapshot);
  }
}

void Analyzer::resetPerBlockState() {
  CurrentState = jeandle::PEABlockState();
  FieldStates.clear();
  FieldDefinitions.clear();
  LockCounts.clear();
  LiveLockEnters.clear();
  Materialized.clear();
}

void Analyzer::recordCFGDeadnessProof(CFGDeadnessProofKind Kind,
                                      Instruction *Killer, Value *Condition,
                                      BasicBlock *ChosenSuccessor) {
  assert(Killer && "CFG deadness proof requires a stable IR killer");
  if (!RecordedCFGProofs.insert(Killer).second)
    return;
  CFGDeadnessProofs.push_back({Kind, Killer, Condition, ChosenSuccessor});
}

std::optional<bool>
Analyzer::foldedTerminatorEdgeIsLive(Instruction *Terminator,
                                     BasicBlock *Succ) {
  Value *Condition = nullptr;
  if (auto *BI = dyn_cast<BranchInst>(Terminator)) {
    if (!BI->isConditional())
      return std::nullopt;
    Condition = BI->getCondition();
  } else if (auto *SI = dyn_cast<SwitchInst>(Terminator)) {
    Condition = SI->getCondition();
  } else {
    return std::nullopt;
  }

  Value *Resolved = Condition;
  SmallPtrSet<Value *, 4> Seen;
  while (Seen.insert(Resolved).second)
    if (Value *Replacement = Aliases.getScalarAlias(Resolved))
      Resolved = Replacement;
    else
      break;
  auto *CI = dyn_cast<ConstantInt>(Resolved);
  if (!CI)
    return std::nullopt;

  // Literal IR conditions need no transactional proof. Any condition reached
  // through the attempt-local scalar replacement plan does: late eligibility
  // filtering may remove the effect that made Resolved constant.
  if (Resolved != Condition) {
    if (SuppressedCFGProofs.count(Terminator))
      return std::nullopt;
  }

  BasicBlock *Chosen = nullptr;
  if (auto *BI = dyn_cast<BranchInst>(Terminator))
    Chosen = BI->getSuccessor(CI->isZero() ? 1 : 0);
  else
    Chosen =
        cast<SwitchInst>(Terminator)->findCaseValue(CI)->getCaseSuccessor();

  bool KillsAnyEdge =
      llvm::any_of(successors(Terminator->getParent()),
                   [&](BasicBlock *Target) { return Target != Chosen; });
  if (Resolved != Condition && KillsAnyEdge)
    recordCFGDeadnessProof(CFGDeadnessProofKind::FoldedTerminatorCondition,
                           Terminator, Condition, Chosen);

  // Chosen is computed once for the whole terminator, so duplicate switch
  // cases are aggregated by (Pred, Succ): any feasible case selecting Succ
  // makes every query for that source/destination pair Live.
  return Chosen == Succ;
}

EdgeContribution Analyzer::contributionFor(BasicBlock *Pred, BasicBlock *Succ) {
  assert(EdgeExitViewScopeDepth != 0 &&
         "contributionFor requires a scoped edge-exit-view cache");
  auto It = BlockExits.find(Pred);
  if (It == BlockExits.end())
    return EdgeContribution::unseen();
  BlockExitInfo &Info = It->second;
  if (Info.IsDead)
    return EdgeContribution::dead();
  if (std::optional<bool> IsLive =
          foldedTerminatorEdgeIsLive(Pred->getTerminator(), Succ)) {
    if (!*IsLive) {
      Result.NeedsCFGCleanup = true;
      return EdgeContribution::dead();
    }
  }
  // When the pred ends in an InvokeInst whose unwind dest is `Succ`,
  // the unwind edge participates in state-splitting.
  BlockExitData *Base = &Info;
  if (Info.TerminatorInvoke && Info.UnwindDest == Succ) {
    if (Info.UnwindEdgeKilled)
      return EdgeContribution::dead();
    if (Info.UnwindData)
      Base = &*Info.UnwindData;
  }
  // Start from the correct normal/unwind snapshot, then overlay every
  // materialization whose replay is confined to this incoming edge. Build one
  // view per edge in the current scope: merge-driven materialization mutates
  // that same view directly, so retries and cascade members need no rebuild.
  // The unique_ptr keeps earlier pointers stable as other edges are collected.
  std::unique_ptr<BlockExitData> &Storage = EdgeExitViews[Pred][Succ];
  if (!Storage) {
    Storage = std::make_unique<BlockExitData>();
    *Storage = *Base;
    auto PIt = MaterializedAtPred.find(Pred);
    if (PIt != MaterializedAtPred.end()) {
      auto SIt = PIt->second.find(Succ);
      if (SIt != PIt->second.end())
        for (jeandle::ObjectID ID : SIt->second)
          if (Eligible.lookup(ID))
            markObjectMaterializedInExitData(*Storage, ID, realIdentityOf(ID));
    }
  }
  return EdgeContribution::live(Storage.get());
}

bool Analyzer::isMaterializedAtPred(BasicBlock *Pred, BasicBlock *M,
                                    jeandle::ObjectID ID) {
  auto It = MaterializedAtPred.find(Pred);
  if (It == MaterializedAtPred.end())
    return false;
  auto MIt = It->second.find(M);
  if (MIt == It->second.end())
    return false;
  return MIt->second.count(ID);
}

// Copy one predecessor's exit snapshot into the live per-block state (the
// single-live-pred fast path). Every map copy skips ineligible objects —
// except FieldDefinitions, whose reaching stores must keep flowing to
// consumers even for an ineligible (kept-real) object; a marker ObjectState
// in CurrentState preserves ObjectID resolution there while all folds stay
// gated by Eligible. The inherited live lock stack is additionally mirrored
// onto each VO's ObjectState so the on-VO and analyzer-side views agree from
// the block's first instruction.
void Analyzer::inheritFromExit(const BlockExitData &Exit) {
  for (jeandle::ObjectID ID : Exit.Virtuals) {
    if (!Eligible.lookup(ID))
      continue;
    CurrentState.addObject(ID, jeandle::ObjectState());
  }
  for (jeandle::ObjectID ID : Exit.Materialized) {
    if (!Eligible.lookup(ID))
      continue;
    jeandle::ObjectState OS;
    // Ordinary VOs reuse OrigAlloc.  A materialized Case-C identity uses its
    // defining pointer PHI, which dominates every exit carrying its ID.
    OS.escape(realIdentityOf(ID));
    CurrentState.addObject(ID, std::move(OS));
    Materialized.insert(ID);
  }
  for (auto &Kv : Exit.FieldStates) {
    if (!Eligible.lookup(Kv.first))
      continue;
    FieldStates[Kv.first] = Kv.second;
  }
  for (auto &Kv : Exit.FieldDefinitions) {
    FieldDefinitions[Kv.first] = Kv.second;
    // An ineligible object is real in the final IR, but reaching definitions
    // of stores provisionally eliminated before the bail still need to flow to
    // later consumers. Keep a virtual marker only for ObjectID resolution; all
    // folds and store elimination remain gated by Eligible.
    if (!Eligible.lookup(Kv.first) && !Kv.second.empty() &&
        !CurrentState.hasObjectState(Kv.first))
      CurrentState.addObject(Kv.first, jeandle::ObjectState());
  }
  for (auto &Kv : Exit.LockCounts) {
    if (!Eligible.lookup(Kv.first))
      continue;
    if (Kv.second != 0)
      LockCounts[Kv.first] = Kv.second;
  }
  // Inherit the live monitorenter stack alongside LockCounts. The
  // CallBase* identities are still valid (we never erase IR during analysis).
  for (auto &Kv : Exit.LiveLockEnters) {
    if (!Eligible.lookup(Kv.first))
      continue;
    if (!Kv.second.empty())
      LiveLockEnters[Kv.first] = Kv.second;
  }
  // Mirror the inherited live stack onto each per-VO ObjectState's
  // Locks so the on-VO view matches the analyzer-side DenseMap from the
  // first instruction of this block. Without this, ObjectState::Locks would
  // be empty for an inherited VO until the first foldMonitorEnter in this
  // block, and a downstream exitDataEquivalent / shallowEquals comparison
  // (e.g. merge fast path) would over-collapse two VOs with structurally
  // different lock states.
  for (auto &Kv : Exit.LiveLockEnters) {
    if (!Eligible.lookup(Kv.first))
      continue;
    if (!CurrentState.hasObjectState(Kv.first))
      continue;
    jeandle::ObjectState &OS =
        CurrentState.getObjectStateForModification(Kv.first);
    if (!OS.isVirtual())
      continue;
    for (const LockEnter &LE : Kv.second)
      OS.addLock({LE.Call, LE.BytecodeDepth});
  }
}

PHINode *Analyzer::createUnparentedPhi(Type *Ty, unsigned N,
                                       const Twine &Name) {
  PHINode *Phi = PHINode::Create(Ty, N, Name);
  Result.OwnedPhis.emplace_back(Phi);
  return Phi;
}

// Return a stable unparented PHI shell for one (in-loop merge block, ID,
// offset) field merge. The cache hit path returns the existing shell; the
// miss path creates one sized for BB's full predecessor fan-in and registers
// it in Result.OwnedLoopFieldPhis (which survives loop rollback) and the
// LoopFieldPhiCache. See the declaration for why stability is required.
PHINode *Analyzer::getOrCreateLoopFieldPhi(BasicBlock *BB, jeandle::ObjectID ID,
                                           int64_t Offset, Type *Ty, unsigned N,
                                           const Twine &Name) {
  // Outside any loop (LI.getLoopFor(BB) == nullptr), fall back to the
  // single-shot OwnedPhis path. Inside a loop — including NON-HEADER in-loop
  // merge blocks — the PHI is cached so its Value* stays stable across
  // fixpoint iterations. B and B' compare FieldValues by Value* and the next
  // explicit B seed may carry a prior merge result, so cached PHIs live in
  // OwnedLoopFieldPhis, which restoreLoopSnapshot does not pop.
  if (!LI.getLoopFor(BB))
    return createUnparentedPhi(Ty, N, Name);

  // At an in-loop BB, size the PHI shell for the block's FULL
  // fan-in (every predecessor — forward edge AND back edge), regardless of
  // how many incomings the caller has visited on this particular iteration.
  // Without this, iter 1 (which only sees forward-edge preds before the
  // body has been walked) reserves capacity 1; iter 2's caller hands N=2
  // and PHINode::reserveOperand has to grow the operand list — wasted work
  // and (defensively) avoids a stale-capacity surprise if the IR has more
  // preds than the analyzer thinks. BB->getNumPredecessors() observes ALL
  // preds even on first-pass analysis.
  unsigned FullN =
      static_cast<unsigned>(std::distance(pred_begin(BB), pred_end(BB)));
  if (FullN < N)
    FullN = N; // caller knows of more than IR shows; should not occur on
               // well-formed IR but cheap to honour.

  LoopPhiKey K{BB, ID, Offset};
  auto It = LoopFieldPhiCache.find(K);
  if (It != LoopFieldPhiCache.end()) {
    // The cache holds a WeakTrackingVH, which auto-nulls if the PHI was
    // deleted via some other code path, so validity is an O(1) null check
    // (no OwnedLoopFieldPhis scan).
    PHINode *Cached = cast_or_null<PHINode>(static_cast<Value *>(It->second));
    // During analysis the PHI is an unparented shell — the transform pass is
    // responsible for inserting it into the merge block and calling
    // addIncoming. Therefore a healthy cached PHI has
    // getNumIncomingValues() == 0 at every analysis-time touch. Any non-zero
    // count indicates a leak (e.g. an earlier code path mistakenly called
    // addIncoming on the shell) and we drop the cache entry to force
    // re-creation.
    if (Cached && Cached->getType() == Ty &&
        Cached->getNumIncomingValues() == 0) {
      // Invariant: incoming lists are passed to the transform through the
      // CreatePHI effect's PHIIncomingValues / PHIIncomingBlocks lists,
      // never via Phi->addIncoming() during analysis. A healthy cached
      // shell therefore always has zero incomings here, and the loop below
      // is a defensive no-op, spelled out to keep the post-condition
      // explicit ("cache hit returns an empty shell").
      while (Cached->getNumIncomingValues() > 0)
        Cached->removeIncomingValue(Cached->getNumIncomingValues() - 1u,
                                    /*DeletePHIIfEmpty=*/false);
      return Cached;
    }
    // Cache stale (rare): drop entry and fall through to recreate.
    LoopFieldPhiCache.erase(It);
  }

  PHINode *Phi = PHINode::Create(Ty, FullN, Name);
  Result.OwnedLoopFieldPhis.emplace_back(Phi);
  LoopFieldPhiCache[K] = Phi;
  return Phi;
}

// Type-coercion for processLoad.
//
// Handles loads that read a WHOLE stored slot, possibly reinterpreting its
// type: the trivial same-type return, a same-bit-width primitive↔primitive
// BitCast (Float↔Int, Half↔i16, etc.), and pointer↔pointer passthrough.
//
// The caller, processLoad, rejects sub-slot ("incomplete field") reads — a load
// whose within-slot byte offset is nonzero — before reaching this routine,
// forcing the object to materialize instead. Widening loads (EntryWidth <
// LoadWidth), narrower whole-slot loads (EntryWidth > LoadWidth), and
// pointer↔primitive mismatches (stable-slot-kind invariant) bail here.
// TODO(unsafe-inliner): see the access dispatch (processStore/processLoad).
//
// The same-bit-width bitcast is registered (unparented) in Result.OwnedInsts;
// the transform's ReplaceLoad handler splices it before the target load.
Value *Analyzer::coerceToType(Value *V, Type *LoadTy,
                              Instruction *InsertContext) {
  Type *VTy = V->getType();
  if (VTy == LoadTy)
    return V;
  if (!VTy->isSized() || !LoadTy->isSized())
    return nullptr;
  uint64_t VBits = DL.getTypeSizeInBits(VTy);
  uint64_t LBits = DL.getTypeSizeInBits(LoadTy);

  // Stable-slot-kind invariant: ref↔primitive at the same slot must
  // materialize.
  if (VTy->isPointerTy() != LoadTy->isPointerTy())
    return nullptr;

  // Pointer↔pointer: pointers don't truncate. Require matching bit width and
  // address spaces. Same-AS same-bitwidth pointers are already type-identical
  // under opaque pointers, so a true pointer coercion is rare; defend against
  // the cross-AS case.
  if (VTy->isPointerTy() && LoadTy->isPointerTy()) {
    if (VBits != LBits)
      return nullptr;
    if (VTy->getPointerAddressSpace() != LoadTy->getPointerAddressSpace())
      return nullptr;
    return V;
  }

  // Both primitives from here. Sub-byte loads (e.g. i1) are bailed: Java
  // field slots are byte-granular, so no tracked slot needs a bit-level
  // shift/mask reinterpret.
  if (LBits == 0 || (LBits % 8) != 0)
    return nullptr;
  if (VBits == 0 || (VBits % 8) != 0)
    return nullptr;

  // Same bit width → BitCast (Float↔Int, Half↔i16, etc.).
  if (VBits == LBits) {
    if (!CastInst::isBitCastable(VTy, LoadTy))
      return nullptr;
    Instruction *Cast =
        CastInst::Create(Instruction::BitCast, V, LoadTy, "pea.coerce",
                         /*InsertBefore=*/nullptr);
    if (InsertContext)
      Cast->setDebugLoc(InsertContext->getDebugLoc());
    Result.OwnedInsts.emplace_back(Cast);
    return Cast;
  }

  // Anything else bails: a narrower whole-slot load (EntryWidth > LoadWidth),
  // a widening load (EntryWidth < LoadWidth), and any other cross-width
  // mismatch. The caller marks the VO ineligible so the original
  // alloc/store/load survive in IR.
  return nullptr;
}

Value *Analyzer::widenDeoptScalar(Value *V, Instruction *InsertContext) {
  Type *Ty = V->getType();
  if (!Ty->isIntegerTy() || Ty->getIntegerBitWidth() >= 32 || isa<Constant>(V))
    return V;
  Instruction *ZExt =
      CastInst::Create(Instruction::ZExt, V, Type::getInt32Ty(V->getContext()),
                       "pea.deopt.widen", /*InsertBefore=*/nullptr);
  if (InsertContext)
    ZExt->setDebugLoc(InsertContext->getDebugLoc());
  Result.OwnedInsts.emplace_back(ZExt);
  return ZExt;
}

Analyzer::MergeProcessor::MergeProcessor(Analyzer &A, BasicBlock *BB)
    : A(A), BB(BB), CurrentState(A.CurrentState), FieldStates(A.FieldStates),
      FieldDefinitions(A.FieldDefinitions), Eligible(A.Eligible),
      LockCounts(A.LockCounts), LiveLockEnters(A.LiveLockEnters),
      Materialized(A.Materialized), Aliases(A.Aliases), Result(A.Result),
      PendingMergePhis(A.PendingMergePhis) {}

// Merge all of BB's predecessor exit snapshots into the live per-block
// state: collect the edge contributions, intersect the tracked IDs, and run
// the merge fixpoint (see MergeProcessor).
void Analyzer::mergeStates(BasicBlock *BB) {
  ScopedEdgeExitViews EdgeViews(*this);
  MergeProcessor MP(*this, BB);
  MP.run();
}

// Drive the merge of BB's predecessor exit snapshots: collect the per-edge
// contributions (preserving the full structural predecessor order so dead
// slots later receive poison at their original position), intersect the
// tracked IDs, then iterate the merge fixpoint — per-VO disposition via
// mergeObjectState and pointer-PHI classification via processBlockPhis —
// until an iteration materializes nothing new on any pred edge. Invariants:
// the per-block output state is empty at entry (processBlock resets it), so
// a retry can reset to empty in lieu of a snapshot/restore; CreatePHI
// effects stay buffered in MergeEffects until the fixpoint converges and are
// committed to PendingMergePhis[BB] at the end; per-pred materialization
// side effects are monotone and deliberately persist across retries.
void Analyzer::MergeProcessor::run() {
  // Preserve the full structural predecessor order while compacting only Live
  // snapshots into Preds. Dead entries remain in FullContributions so field
  // PHIs receive poison at the same original slot; Unseen loop entries are
  // omitted until the existing loop fixpoint revisits and backfills them.
  for (BasicBlock *P : predecessors(BB)) {
    unsigned OriginalIndex = FullPredBBs.size();
    EdgeContribution Contribution = A.contributionFor(P, BB);
    FullPredBBs.push_back(P);
    FullContributions.push_back(Contribution.Kind);
    if (!Contribution.isLive())
      continue;
    PredBBs.push_back(P);
    Preds.push_back(Contribution.Data);
    LiveOriginalIndices.push_back(OriginalIndex);
  }
  if (Preds.empty()) {
    // processBlock normally classifies this block as Dead or deferred before
    // constructing a MergeProcessor. Direct loop post-body merges may still
    // reach here while every input is Unseen; they contribute no state until
    // the next fixpoint pass.
    return;
  }
  // The byte-equivalence fast path runs INSIDE the do/while below, including
  // the degenerate one-live-predecessor case. Keeping that case in the same
  // retry loop is required when processBlockPhis first materializes an
  // incoming: the block body and any earlier PHI aliases must be rebuilt from
  // the updated target-local predecessor view.

  // Only IDs in the intersection of every predecessor's tracked set may
  // remain unified at BB's entry; any ID present on some preds but not all is
  // dropped here (processBlockPhis Case-A fallback handles it by materialising
  // the virtual incomings at the per-pred terminator).
  intersectVirtualObjects();

  // Iterative merge stabilization. A nested materialize triggered inside
  // per-field PHI synthesis can invalidate earlier per-VO decisions, so the
  // per-VO loop is re-run whenever any materializeAtPredFromExitInfo call
  // emits an Effect.
  //
  // The retry discards this merge's partial OUTPUT and re-derives it from a
  // clean slate. Because processBlock calls resetPerBlockState() before
  // invoking the MergeProcessor, the output state (CurrentState /
  // FieldStates / LockCounts / LiveLockEnters / Materialized) is always EMPTY
  // at run() entry, so resetting to empty is equivalent to a snapshot/restore.
  // Merge-block-local CreatePHI effects are buffered in MergeEffects (not
  // committed to PendingMergePhis[BB] until the fixpoint converges), so a
  // retry just clears the buffer. Materialize side-effects (per-pred ExitInfo
  // flips, MaterializedAtPred, per-pred BlockEffects, Eligible flags, and
  // Result.NextSeqNo) survive across retries by design — they are monotone,
  // real effects. Every BB-phi alias is cleared before each iteration's
  // processBlockPhis, so aliases are re-derived idempotently and need no
  // snapshot. Progress is monotone, so the cap of 10 is a defensive safety
  // net only.
  constexpr unsigned MaxRetries = 10;
  size_t OwnedPhisMark = Result.OwnedPhis.size();
  size_t OwnedInstsMark = Result.OwnedInsts.size();
  unsigned Iter = 0;
  bool Changed = false;

  do {
    if (Iter > 0) {
      // Discard this merge's partial output and start the iteration clean.
      // (ExitInfo / MaterializedAtPred / per-pred BlockEffects / Eligible /
      // NextSeqNo all carry over by design.)
      CurrentState = jeandle::PEABlockState();
      FieldStates.clear();
      FieldDefinitions.clear();
      LockCounts.clear();
      LiveLockEnters.clear();
      Materialized.clear();
      MergeEffects.clear();
      A.deleteOwnedSince(OwnedPhisMark, OwnedInstsMark);
    }
    if (Iter >= MaxRetries) {
      // Safety net. Cap reached — bail every VO in the working set so the
      // original IR survives at this merge. This indicates a pathology in the
      // input.
      LLVM_DEBUG(dbgs() << "PEA: mergeStates retry cap (" << MaxRetries
                        << ") reached at BB '" << BB->getName()
                        << "'; bailing all VOs at merge.\n");
      for (jeandle::ObjectID ID : IDs) {
        for (const BlockExitData *P : Preds)
          A.observeFieldDefinitions(ID, P->FieldDefinitions);
        A.markIneligible(ID);
      }
      return;
    }
    ++Iter;
    Changed = false;

    // Byte-equivalence fast path, re-evaluated each iteration. If every
    // predecessor's exit view is byte-equivalent, the merge is degenerate:
    // inherit preds[0] directly and skip the O(|preds|*|virtuals|*|offsets|)
    // per-VO merge. processBlockPhis still runs to alias any pointer PHIs.
    //
    // SOUNDNESS (why this is safe inside the retry loop): the comparison is
    // a full content compare over the detached per-edge exit views handed
    // out by contributionFor, and a merge-driven materialize cascade mutates
    // only the one per-edge view it replays on — never a pred snapshot
    // shared with sibling edges — so a later iteration compares post-cascade
    // content. The AnyMaterialized gate below then suppresses the fast path
    // as soon as preds[0] carries any materialized object (the typical
    // post-cascade shape). Byte-equivalence therefore effectively only fires
    // on the first iteration, before any materialization — exactly when an
    // all-equivalent result is genuinely identical.
    {
      // Two preds can both report the same OrigAlloc as materialized yet carry
      // different edge-local field or lock replay. Byte-equivalent exits are
      // then not genuinely identical, so the fast path must not fire when any
      // object is materialized; the per-VO merge must reconcile those effects.
      bool AnyMaterialized = !Preds[0]->Materialized.empty();
      bool AllSame = !AnyMaterialized;
      for (unsigned i = 1; AllSame && i < Preds.size(); ++i) {
        if (!A.exitDataEquivalent(*Preds[0], *Preds[i])) {
          AllSame = false;
          break;
        }
      }
      if (AllSame) {
        A.inheritFromExit(*Preds[0]);
        uint32_t PrePhiSeqNo = Result.NextSeqNo;
        A.processBlockPhis(BB, MergeEffects);
        if (Result.NextSeqNo != PrePhiSeqNo) {
          // Case A changed one or more target-local predecessor views. Retry
          // the whole merge so per-object state, earlier PHI aliases, and the
          // block body all observe those edge-local materializations. The
          // iteration prologue clears this partial output and MergeEffects.
          Changed = true;
          continue;
        }
        break; // exit the do/while; fall through to the MergeEffects commit.
      }
    }

    mergeIneligibleFieldDefinitions();

    for (jeandle::ObjectID ID : IDs) {
      if (!Eligible.lookup(ID))
        continue;
      Changed |= mergeObjectState(ID);
    }

    // Run the PHI loop INSIDE the merge do-while, with every BB-phi alias
    // reset first. Case-A fallback and Case-C synthesis both call
    // materializeAtPredFromExitInfo on inner / per-pred VOs; any such call
    // mutates a pred's ExitInfo (Virtuals->Materialized), which can
    // invalidate the per-VO decisions just made. We detect the work via
    // Result.NextSeqNo delta and set Changed=true so the next iter re-runs
    // the per-VO loop against the updated pred ExitInfos. processBlockPhis
    // routes its CreatePHI effects into MergeEffects (retry-cleared), the
    // same buffer discipline the per-VO loop uses for its field PHIs.
    for (PHINode &Phi : BB->phis())
      Aliases.resetAlias(&Phi);
    {
      uint32_t PrePhiSeqNo = Result.NextSeqNo;
      A.processBlockPhis(BB, MergeEffects);
      if (Result.NextSeqNo != PrePhiSeqNo)
        Changed = true;
    }
  } while (Changed);

  // Commit this merge's deferred CreatePHI effects to PendingMergePhis[BB].
  // processBlock drains the list before its body walk, assigning each a fresh
  // SeqNo after any merge-time per-pred Materialize effect.
  PendingMergePhis[BB].addAll(MergeEffects);
}

// Intersect the tracked IDs: keep only objects tracked (virtual or
// materialized) by EVERY predecessor. Only these may remain unified at the
// merge entry.
void Analyzer::MergeProcessor::intersectVirtualObjects() {
  DenseSet<jeandle::ObjectID> Intersect;
  for (jeandle::ObjectID ID : Preds[0]->Virtuals)
    Intersect.insert(ID);
  for (jeandle::ObjectID ID : Preds[0]->Materialized)
    Intersect.insert(ID);
  for (unsigned i = 1; i < Preds.size(); ++i) {
    // Test membership directly against each pred's existing tracked sets
    // (Preds[i]->Virtuals/Materialized are already DenseSets) rather than
    // materializing a per-predecessor copy.
    SmallVector<jeandle::ObjectID, 8> ToRemove;
    for (jeandle::ObjectID ID : Intersect)
      if (!Preds[i]->Virtuals.count(ID) && !Preds[i]->Materialized.count(ID))
        ToRemove.push_back(ID);
    for (jeandle::ObjectID ID : ToRemove)
      Intersect.erase(ID);
  }
  IDs.assign(Intersect.begin(), Intersect.end());
  llvm::sort(IDs); // deterministic order for ineligibility/marking effects.
}

// Union every pred's reaching field definitions for ineligible objects into
// the merged state and give each such object a marker ObjectState. The
// objects themselves stay real; the definitions must keep flowing so later
// consumers can still attribute stores that were provisionally eliminated
// before the bail.
void Analyzer::MergeProcessor::mergeIneligibleFieldDefinitions() {
  SmallDenseSet<jeandle::ObjectID, 8> IDsWithDefinitions;
  for (const BlockExitData *P : Preds) {
    for (const auto &IDKV : P->FieldDefinitions) {
      jeandle::ObjectID ID = IDKV.first;
      if (Eligible.lookup(ID))
        continue;
      for (const auto &OffKV : IDKV.second) {
        FieldDefinitionSet &Defs = FieldDefinitions[ID][OffKV.first];
        Defs.insert(OffKV.second.begin(), OffKV.second.end());
        if (!Defs.empty())
          IDsWithDefinitions.insert(ID);
      }
    }
  }

  // The marker lets downstream pointer resolution find the abandoned root so
  // a real consumer can observe the reaching eliminated definitions. It does
  // not make the object eligible for any virtual fold or store elimination.
  for (jeandle::ObjectID ID : IDsWithDefinitions)
    if (!CurrentState.hasObjectState(ID))
      CurrentState.addObject(ID, jeandle::ObjectState());
}

// Decide the merged disposition of one object across all predecessors:
// all-materialized installs OrigAlloc directly (single pred) or funnels into
// materializePredsAndMerge (multi-pred); mixed virtual/materialized state
// materializes the still-virtual preds; all-virtual with matching lock
// counts AND (Call, BytecodeDepth) live-enter stacks goes to the compatible
// field merge (mergeFieldStates); any lock mismatch forces per-pred
// materialization. An object missing on some pred is not merged at all —
// processBlockPhis picks up any LLVM PHI that references it.
// Returns true if a materializeAtPredFromExitInfo call emitted an Effect
// this iteration (the run() do/while re-runs on true).
bool Analyzer::MergeProcessor::mergeObjectState(jeandle::ObjectID ID) {
  // Per-pred disposition.
  bool AllVirtual = true;
  bool AllMaterialized = true;
  for (const auto *P : Preds) {
    bool V = P->Virtuals.count(ID);
    bool M = P->Materialized.count(ID);
    if (!V)
      AllVirtual = false;
    if (!M)
      AllMaterialized = false;
  }

  if (AllMaterialized) {
    // Every incoming path already materialized the object. Under
    // reuse-OrigAlloc the materialized value is OrigAlloc on every edge (it
    // dominates every escape point by SSA), so there is no per-pred pointer
    // divergence to reconcile.
    //
    // `Preds.size() > 1` is load-bearing here: with a single predecessor
    // OrigAlloc is the correct merged value and we install it directly. A
    // multi-pred merge still installs a merged materialized state via
    // materializePredsAndMerge (no virtuals to materialize, but the common
    // path records OrigAlloc for downstream consumers and the loop-fixpoint
    // convergence check).
    if (Preds.size() == 1) {
      jeandle::ObjectState OS;
      OS.escape(A.realIdentityOf(ID));
      CurrentState.addObject(ID, std::move(OS));
      Materialized.insert(ID);
      return false;
    }
    return materializePredsAndMerge(ID);
  }

  if (!AllVirtual) {
    // Mixed (virtual on some paths, materialized or missing on others).
    // Short-circuit when the object isn't tracked on every pred (e.g., an
    // LLVM PHI mixing a virtual incoming from one branch and an unrelated
    // pointer from another). The merge entry simply doesn't carry this
    // ObjectID; processBlockPhis below picks up any LLVM PHI that references
    // it and materializes the virtual incomings.
    bool MissingOnSomePred = false;
    for (auto *P : Preds) {
      if (!P->Materialized.count(ID) && !P->Virtuals.count(ID)) {
        MissingOnSomePred = true;
        break;
      }
    }
    if (MissingOnSomePred)
      return false;

    // Mixed virtual+materialized merge: materialize each still-virtual pred
    // at its predecessor-end. Under reuse-OrigAlloc the one dominating
    // OrigAlloc is the merged value on every edge, so no pointer PHI is
    // needed; field and lock replay remains edge-local.
    return materializePredsAndMerge(ID);
  }

  // All preds report Virtual: check lock counts and live enter-stacks.
  unsigned RefLC = Preds[0]->LockCounts.lookup(ID);
  bool LocksMatch = true;
  for (const auto *P : Preds) {
    if (P->LockCounts.lookup(ID) != RefLC) {
      LocksMatch = false;
      break;
    }
  }
  bool StacksMatch = true;
  if (LocksMatch && RefLC != 0) {
    // Compare (Call, BytecodeDepth) so two paths that re-entered the SAME
    // call site but at different bytecode-level depths are distinct stacks:
    // lock capture/re-emit at a downstream escape would re-emit the same lock
    // set either way, so bytecode depth is what distinguishes the two paths.
    const auto &RefStack = Preds[0]->LiveLockEnters.lookup(ID);
    for (const auto *P : Preds) {
      const auto &S = P->LiveLockEnters.lookup(ID);
      if (S.size() != RefStack.size()) {
        StacksMatch = false;
        break;
      }
      for (unsigned i = 0; i < S.size(); ++i) {
        if (S[i].Call != RefStack[i].Call ||
            S[i].BytecodeDepth != RefStack[i].BytecodeDepth) {
          StacksMatch = false;
          break;
        }
      }
      if (!StacksMatch)
        break;
    }
  }

  if (AllVirtual && LocksMatch && StacksMatch)
    return mergeFieldStates(ID);

  // Otherwise a lock-count or live-enter-stack mismatch forces per-pred
  // materialization. Do it in a SINGLE pass (each pred carries its OWN lock
  // list, so replay emits exactly that pred's monitorenter set — no
  // synthesized enters are added on the lower-count side). On retry every
  // pred has flipped to Materialized, and the unique OrigAlloc value keeps
  // the merged state stable.
  return materializePredsAndMerge(ID);
}

// Shared materialization tail of mergeObjectState: replay every still-virtual
// pred at its predecessor end and install a merged materialized ObjectState
// whose value is the original allocation. Reached for mixed
// virtual/materialized state, all-materialized multi-pred merges, and
// lock/stack mismatches.
// Returns true if a per-pred materialize emitted an Effect this iteration
// (the run() do/while re-runs on true).
// TODO(ensure-virtualized): when an EnsureVirtualized bit lands on ObjectState,
// downgrade it here per-pred (Graal setEnsureVirtualized(false) where not all
// preds agree) — this entry covers the AllMaterialized-divergence arm of
// mergeObjectState.
bool Analyzer::MergeProcessor::materializePredsAndMerge(jeandle::ObjectID ID) {
  bool Mat = false;
  for (unsigned i = 0; i < Preds.size(); ++i) {
    if (!Eligible.lookup(ID))
      break;
    // Materialize any still-virtual pred at its terminator (each carrying its
    // OWN lock list). AllMaterialized-multi-pred has no virtual preds, so this
    // is a no-op there; lock/stack mismatch materializes each one.
    if (Preds[i]->Virtuals.count(ID)) {
      uint32_t PreSeqNo = Result.NextSeqNo;
      // The materialization targets this one incoming edge. OrigAlloc
      // dominates every successor as an SSA value, but field and monitor
      // replay are side effects and must retain that edge control dependence.
      // The transform splits a multi-successor predecessor edge before
      // applying these effects; a single-successor predecessor already is an
      // edge-specific insertion point.
      A.materializeAtPredFromExitInfo(ID, PredBBs[i], *Preds[i],
                                      /*EdgeLocal=*/true, MatReason::Merge,
                                      /*TargetMerge=*/BB);
      if (Result.NextSeqNo != PreSeqNo)
        Mat = true;
    }
  }
  // An unsplittable edge, unavailable replay value, or failed prerequisite
  // cascade can make ID ineligible while processing a predecessor. Do not
  // install the merged state: commit() drops all of ID's effects and
  // downstream users retain the real OrigAlloc. Mat still reports whether an
  // earlier predecessor emitted effects so the retry observes the new
  // eligibility state.
  if (!Eligible.lookup(ID))
    return Mat;

  // Install the unique materialized value directly. OrigAlloc dominates every
  // edge, so its identity is stable across loop-fixpoint retries and no
  // analyzer-only placeholder is needed.
  jeandle::ObjectState OS;
  OS.escape(A.realIdentityOf(ID));
  CurrentState.addObject(ID, std::move(OS));
  Materialized.insert(ID);
  return Mat;
}

// Append one (value, block) incoming pair per structural predecessor slot to
// a merge PHI effect: live contributions supply their merged value in order,
// dead contributions get poison at their original slot, and unseen loop
// entries are skipped (the loop fixpoint backfills them on revisit).
void Analyzer::MergeProcessor::appendFullPhiInputs(
    jeandle::CreatePHIEffect &Effect, ArrayRef<Value *> LiveValues,
    Type *PhiType) const {
  assert(LiveValues.size() == Preds.size() &&
         "one field value is required for every live contribution");
  unsigned LiveIndex = 0;
  for (unsigned OriginalIndex = 0; OriginalIndex < FullPredBBs.size();
       ++OriginalIndex) {
    EdgeContributionKind Kind = FullContributions[OriginalIndex];
    if (Kind == EdgeContributionKind::Unseen)
      continue;
    Value *Incoming = nullptr;
    if (Kind == EdgeContributionKind::Dead)
      Incoming = PoisonValue::get(PhiType);
    else {
      assert(LiveIndex < LiveOriginalIndices.size() &&
             LiveOriginalIndices[LiveIndex] == OriginalIndex &&
             "live merge input lost its original predecessor index");
      Incoming = LiveValues[LiveIndex++];
    }
    Effect.PHIIncomingValues.push_back(Incoming);
    Effect.PHIIncomingBlocks.push_back(FullPredBBs[OriginalIndex]);
  }
  assert(LiveIndex == LiveValues.size() &&
         "live-to-original predecessor mapping must be complete");
}

// Compatible-branch field merge for a virtual object whose locks agree
// across all predecessors: per-offset field-PHI synthesis. Identical entries
// flow straight into the merged state; disagreements synthesize a per-offset
// PHI (heap-pointer entries promote to a generic Java-heap pointer type;
// integer entries promote to the widest width and zext the narrower inputs).
// A VirtualRef entry materializes the inner VO on that pred's incoming edge
// first. Any per-offset failure materializes the whole object at every pred
// via materializePredsAndMerge rather than dropping the offending offset.
// Returns true if a nested inner-VO materialize emitted an Effect (retry).
//
// TODO(mergeObjectStates-two-slot-and-bytearray): mirror Graal's
// virtualByteCount / twoSlotKinds compatibility pre-scan
// (Graal PartialEscapeClosure) and widened-PHI synthesis.
// The integer-widening zext below is guarded so a narrow pred with a
// conflicting non-default scalar in the wide type's byte span bails instead
// of discarding adjacent-byte contributions. That widening is unreachable by
// construction — processStore's getOrCreateFieldIndex bails on a width
// mismatch at the same offset, so two preds never present different integer
// widths for one offset here — but the guard keeps the merge sound if that
// ever changes (e.g. byte-array write decomposition under unsafe support).
bool Analyzer::MergeProcessor::mergeFieldStates(jeandle::ObjectID ID) {
  unsigned RefLC = Preds[0]->LockCounts.lookup(ID); // all preds agree here.
  bool Changed = false;

  // Check field states at every tracked offset. Identical entries flow
  // straight into Merged; disagreements trigger field-PHI synthesis.
  DenseSet<int64_t> Offsets;
  for (const auto *P : Preds) {
    auto FIt = P->FieldStates.find(ID);
    if (FIt == P->FieldStates.end())
      continue;
    for (auto &Kv : FIt->second)
      Offsets.insert(Kv.first);
  }
  SmallVector<int64_t, 8> SortedOffsets(Offsets.begin(), Offsets.end());
  llvm::sort(SortedOffsets); // determinism
  bool BailObject = false;
  DenseMap<int64_t, jeandle::FieldValue> Merged;
  DenseMap<int64_t, FieldDefinitionSet> MergedDefinitions;
  for (int64_t Off : SortedOffsets) {
    FieldDefinitionSet &Defs = MergedDefinitions[Off];
    for (const auto *P : Preds) {
      auto DIt = P->FieldDefinitions.find(ID);
      if (DIt == P->FieldDefinitions.end())
        continue;
      auto OIt = DIt->second.find(Off);
      if (OIt == DIt->second.end())
        continue;
      Defs.insert(OIt->second.begin(), OIt->second.end());
    }
    if (Defs.empty())
      MergedDefinitions.erase(Off);
  }
  // Snapshot of newly-emitted CreatePHI effects for this object's fields;
  // committed to Result only if every offset succeeds.
  jeandle::EffectList PendingPhiEffects;
  for (int64_t Off : SortedOffsets) {
    // Any field-merge failure makes the whole object incompatible: it is
    // materialized at every predecessor (the materializePredsAndMerge tail
    // below) rather than dropping just the offending offset. Dropping an
    // offset would silently lose the eliminated stores that fed it — a later
    // load of that offset would fold to the Java default instead of the
    // stored value.
    jeandle::FieldValue Ref = jeandle::FieldValue::unknown();
    bool HaveRef = false;
    bool Disagrees = false;
    for (const auto *P : Preds) {
      jeandle::FieldValue FV = jeandle::FieldValue::unknown();
      auto FIt = P->FieldStates.find(ID);
      if (FIt != P->FieldStates.end()) {
        auto OIt = FIt->second.find(Off);
        if (OIt != FIt->second.end())
          FV = OIt->second;
      }
      if (!HaveRef) {
        Ref = FV;
        HaveRef = true;
      } else if (!Ref.shallowEquals(FV)) {
        Disagrees = true;
        break;
      }
    }
    if (!Disagrees) {
      if (!Ref.isUnknown())
        Merged[Off] = Ref;
      continue;
    }

    // Field disagreement at Off — attempt field-PHI synthesis. Decide the
    // merged PHI type. Compatibility: every non-unknown entry's declared type
    // must be identical, OR every non-unknown entry must be a pointer in the
    // Java heap addrspace (PHI is ptr addrspace(1), ref/scalar
    // interchangeable). Additionally allows integer-width promotion: promote
    // the PHI type to the widest integer and zext narrower entries.
    Type *PhiType = nullptr;
    bool AllPointer = true;
    bool AllInteger = true;
    unsigned WidestIntBits = 0;
    for (const auto *P : Preds) {
      auto FIt = P->FieldStates.find(ID);
      if (FIt == P->FieldStates.end())
        continue;
      auto OIt = FIt->second.find(Off);
      if (OIt == FIt->second.end())
        continue;
      const jeandle::FieldValue &FV = OIt->second;
      if (FV.isUnknown())
        continue;
      Type *T = nullptr;
      if (FV.isScalar())
        T = FV.getScalar()->getType();
      else
        T = FV.getDeclaredType();
      if (!T) {
        BailObject = true;
        break;
      }
      if (!T->isPointerTy() ||
          T->getPointerAddressSpace() != jeandle::AddrSpace::JavaHeapAddrSpace)
        AllPointer = false;
      if (T->isIntegerTy()) {
        unsigned B = T->getIntegerBitWidth();
        if (B > WidestIntBits)
          WidestIntBits = B;
      } else {
        AllInteger = false;
      }
      if (!PhiType) {
        PhiType = T;
      } else if (PhiType != T) {
        // Heap-pointer promotion is the existing rule.
        bool BothJavaHeapPtr = PhiType->isPointerTy() && T->isPointerTy() &&
                               PhiType->getPointerAddressSpace() ==
                                   jeandle::AddrSpace::JavaHeapAddrSpace &&
                               T->getPointerAddressSpace() ==
                                   jeandle::AddrSpace::JavaHeapAddrSpace;
        // Integer-widening promotion: both integers, possibly different
        // widths — defer PhiType selection to the widest and emit zext on
        // narrower per-pred inputs below.
        bool BothInteger = PhiType->isIntegerTy() && T->isIntegerTy();
        if (!BothJavaHeapPtr && !BothInteger) {
          BailObject = true;
          break;
        }
        // For the integer case, leave PhiType as the LARGER type (re-picked
        // from WidestIntBits below).
      }
    }
    if (BailObject)
      break;
    if (!PhiType) {
      // Should be unreachable — a disagreement implies at least two distinct
      // non-unknown entries.
      continue;
    }
    if (AllPointer) {
      PhiType = PointerType::get(A.F.getContext(),
                                 jeandle::AddrSpace::JavaHeapAddrSpace);
    } else if (AllInteger && WidestIntBits != 0) {
      // Select the widest integer type as the PHI type and emit zext on
      // narrower per-pred values below.
      PhiType = IntegerType::get(A.F.getContext(), WidestIntBits);
    }

    // Compute per-pred input value.
    SmallVector<Value *, 4> InValues;
    InValues.reserve(Preds.size());
    bool LocalBail = false;
    for (unsigned i = 0; i < Preds.size(); ++i) {
      jeandle::FieldValue FV = jeandle::FieldValue::unknown();
      auto FIt = Preds[i]->FieldStates.find(ID);
      if (FIt != Preds[i]->FieldStates.end()) {
        auto OIt = FIt->second.find(Off);
        if (OIt != FIt->second.end())
          FV = OIt->second;
      }
      Value *In = nullptr;
      if (FV.isUnknown()) {
        In = jeandle::FieldValue::defaultFor(PhiType);
      } else if (FV.isScalar()) {
        Value *V = FV.getScalar();
        if (V->getType() != PhiType) {
          // Integer-widen via zext if both are integers AND V is strictly
          // narrower than PhiType. Other mismatches (scalar at pointer slot,
          // etc.) still LocalBail. Constants are the overwhelming common case
          // (loop-invariant 0/1 stores); non-const zext would need a per-pred
          // CreatePHI shim (TODO(non-const-zext-phi): deferred).
          if (V->getType()->isIntegerTy() && PhiType->isIntegerTy() &&
              V->getType()->getIntegerBitWidth() <
                  PhiType->getIntegerBitWidth()) {
            if (auto *CI = dyn_cast<ConstantInt>(V)) {
              // Widening guard: the narrow pred must have NO conflicting
              // non-default scalar in the wide type's byte span
              // [Off+1, Off+WideBytes), or the zext would discard
              // adjacent-byte contributions.
              unsigned WideBytes = PhiType->getIntegerBitWidth() / 8;
              auto SpanIt = Preds[i]->FieldStates.find(ID);
              for (unsigned B = 1; B < WideBytes; ++B) {
                if (SpanIt == Preds[i]->FieldStates.end())
                  break;
                std::optional<int64_t> Adjacent =
                    jeandle::pea::checkedOffsetAdd(Off,
                                                   static_cast<int64_t>(B));
                if (!Adjacent ||
                    !jeandle::pea::isUsableFieldOffset(*Adjacent)) {
                  LocalBail = true;
                  break;
                }
                auto AOff = SpanIt->second.find(*Adjacent);
                if (AOff == SpanIt->second.end())
                  continue; // missing entry == default
                const jeandle::FieldValue &AFV = AOff->second;
                if (AFV.isUnknown())
                  continue;
                if (AFV.isScalar())
                  if (auto *ACI = dyn_cast<ConstantInt>(AFV.getScalar()))
                    if (ACI->isZero())
                      continue;
                LocalBail = true; // conflicting non-default adjacent byte
                break;
              }
              if (LocalBail)
                break;
              In = ConstantInt::get(
                  PhiType, CI->getValue().zext(PhiType->getIntegerBitWidth()));
            } else {
              LocalBail = true;
              break;
            }
          } else {
            // Scalar with a non-matching primitive type at a pointer slot, or
            // non-integer width mismatch, or value-wider-than-PhiType.
            LocalBail = true;
            break;
          }
        } else {
          In = V;
        }
      } else if (FV.isMaterializedRef()) {
        if (!PhiType->isPointerTy()) {
          LocalBail = true;
          break;
        }
        In = FV.getMaterialized();
      } else if (FV.isVirtualRef()) {
        if (!PhiType->isPointerTy()) {
          LocalBail = true;
          break;
        }
        jeandle::ObjectID InnerID = FV.getVirtualRef();
        // Materialize the inner object at this pred's terminator. After this,
        // the field's effective input value is OrigAlloc(inner) — OrigAlloc is
        // the value at apply (no substitution — the materialized-object / merge
        // PHI is skipped). Track whether this call emitted any Effects via the
        // SeqNo delta.
        uint32_t PreSeqNo = Result.NextSeqNo;
        // This prerequisite belongs to the same incoming edge as the field
        // value PHI. OrigAlloc supplies the value, while replay side effects
        // remain edge-local.
        A.materializeAtPredFromExitInfo(InnerID, PredBBs[i], *Preds[i],
                                        /*EdgeLocal=*/true, MatReason::Phi,
                                        /*TargetMerge=*/BB);
        if (Result.NextSeqNo != PreSeqNo)
          Changed = true;
        // The real input is OrigAlloc for an ordinary inner or SyntheticPhi
        // for a Case-C inner.  It must dominate this predecessor edge; a
        // synthetic PHI only dominates the region that inherited it.
        Value *InnerVal = A.realIdentityOf(InnerID);
        if (auto *RealI = dyn_cast_or_null<Instruction>(InnerVal)) {
          if (!RealI->getParent() ||
              !A.DT.dominates(RealI, PredBBs[i]->getTerminator())) {
            LocalBail = true;
            break;
          }
        }
        // Defensively rewrite this pred's outer-VO FieldStates entry for the
        // just-materialized inner to MaterializedRef so a sibling successor
        // of the pred (other-than-BB) that later inherits from Preds[i] sees
        // the materialized pointer rather than a stale VirtualRef(InnerID).
        Preds[i]->FieldStates[ID][Off] =
            jeandle::FieldValue::materializedRef(InnerVal);
        In = InnerVal;
      } else {
        LocalBail = true;
        break;
      }
      InValues.push_back(In);
    }
    if (LocalBail) {
      // Incompatible per-pred values — the whole object is materialized at
      // every predecessor (see the BailObject comment at the loop head).
      BailObject = true;
      break;
    }

    // Loop-PHI cache: stable PHI across fixpoint iterations.
    PHINode *Phi = A.getOrCreateLoopFieldPhi(BB, ID, Off, PhiType, Preds.size(),
                                             "pea.field.phi");
    A.PhiHome[Phi] = BB;
    auto PE = std::make_unique<jeandle::CreatePHIEffect>();
    PE->Block = BB;
    // SeqNo assigned at drain time; see PendingMergePhis comment.
    PE->SeqNo = 0;
    PE->setMutationOwner(ID);
    PE->PhiInst = Phi;
    PE->PHIType = PhiType;
    PE->FieldOffset = Off;
    appendFullPhiInputs(*PE, InValues, PhiType);
    PendingPhiEffects.add(std::move(PE));

    if (PhiType->isPointerTy())
      Merged[Off] = jeandle::FieldValue::materializedRef(Phi);
    else
      Merged[Off] = jeandle::FieldValue::scalar(Phi);
  }
  if (BailObject) {
    // Incompatible tail: the fields cannot be merged into a coherent virtual
    // state, so replay the object at every predecessor and record OrigAlloc
    // as the merged materialized value. The original allocation survives and
    // each pred's tracked field state is replayed onto it — more precise
    // than abandoning virtualization entirely. Any PendingPhiEffects staged
    // above are simply discarded (never committed to MergeEffects).
    bool MatEmitted = materializePredsAndMerge(ID);
    return MatEmitted || Changed;
  }

  // Commit this object's field-PHI effects to the merge's deferred buffer;
  // they are flushed to PendingMergePhis[BB] (and assigned SeqNos) only after
  // the fixpoint converges.
  MergeEffects.addAll(PendingPhiEffects);

  // Case B: object stays virtual at BB entry with the merged field state.
  CurrentState.addObject(ID, jeandle::ObjectState());
  if (!Merged.empty())
    FieldStates[ID] = std::move(Merged);
  if (!MergedDefinitions.empty())
    FieldDefinitions[ID] = std::move(MergedDefinitions);
  if (RefLC != 0) {
    LockCounts[ID] = RefLC;
    // The merged live stack is identical to (any) pred's stack, since the
    // StacksMatch check above succeeded.
    const auto &RefStack = Preds[0]->LiveLockEnters.lookup(ID);
    if (!RefStack.empty())
      LiveLockEnters[ID] = RefStack;
  }
  return Changed;
}

// Close a block-exit snapshot over its VirtualRef targets: a VirtualRef
// field is only meaningful while its target is still virtual in the same
// snapshot. A ref whose target is no longer virtual rewrites to a
// MaterializedRef of the target's real identity; a target that was not
// cleanly materialized in this snapshot is also rejected, so a fresh attempt
// rebuilds aliases, stores, merge states, and deopt plans with the target
// real from the start. When the target has no real identity to substitute,
// every holder of such a ref is dropped from the snapshot and rejected as
// well. Dropping a holder can orphan further VirtualRefs that pointed at it,
// so the scan repeats until a pass finds no new holder to drop (the
// do/while fixpoint over HoldersToKeepReal).
void Analyzer::normalizeIneligibleVirtualRefs(BlockExitData &Data) {
  SmallVector<jeandle::ObjectID, 4> HoldersToKeepReal;
  do {
    HoldersToKeepReal.clear();
    for (auto &Holder : Data.FieldStates)
      for (auto &Field : Holder.second) {
        if (!Field.second.isVirtualRef())
          continue;
        jeandle::ObjectID Target = Field.second.getVirtualRef();
        if (Data.Virtuals.count(Target))
          continue;
        Value *RealIdentity = realIdentityOf(Target);
        if (Data.Materialized.count(Target) && RealIdentity) {
          Field.second = jeandle::FieldValue::materializedRef(RealIdentity);
          continue;
        }
        // A VirtualRef without a virtual target is not a closed block state.
        // Reject the target's allocation: a fresh attempt rebuilds aliases,
        // stores, merge states, and deopt plans from the original IR with
        // the target real from the start. Keep this transient snapshot closed
        // as well; the current attempt is discarded before it can be applied.
        observeFieldDefinitions(Target, Data.FieldDefinitions);
        markIneligible(Target, /*FreshRetry=*/true);
        if (RealIdentity) {
          Field.second = jeandle::FieldValue::materializedRef(RealIdentity);
          continue;
        }
        HoldersToKeepReal.push_back(Holder.first);
      }

    llvm::sort(HoldersToKeepReal);
    HoldersToKeepReal.erase(
        std::unique(HoldersToKeepReal.begin(), HoldersToKeepReal.end()),
        HoldersToKeepReal.end());
    for (jeandle::ObjectID Holder : HoldersToKeepReal) {
      observeFieldDefinitions(Holder, Data.FieldDefinitions);
      markIneligible(Holder, /*FreshRetry=*/true);
      Data.Virtuals.erase(Holder);
      Data.Materialized.erase(Holder);
      Data.FieldStates.erase(Holder);
      Data.LockCounts.erase(Holder);
      Data.LiveLockEnters.erase(Holder);
    }
  } while (!HoldersToKeepReal.empty());
}

// Write the live per-block state into Data: each eligible virtual object
// contributes its field values, reaching definitions, lock count, and live
// monitorenter stack; each materialized object contributes just its ID. The
// snapshot is then closed over VirtualRef targets by
// normalizeIneligibleVirtualRefs.
void Analyzer::snapshotExitStateInto(BlockExitData &Data) {
  for (auto &VObjUP : Result.VirtualObjects) {
    jeandle::ObjectID ID = VObjUP->getID();
    if (!Eligible.lookup(ID))
      continue;
    const jeandle::ObjectState *OS = CurrentState.getObjectStateOptional(ID);
    if (!OS)
      continue;
    if (OS->isVirtual()) {
      Data.Virtuals.insert(ID);
      auto FIt = FieldStates.find(ID);
      if (FIt != FieldStates.end() && !FIt->second.empty())
        Data.FieldStates[ID] = FIt->second;
      auto DIt = FieldDefinitions.find(ID);
      if (DIt != FieldDefinitions.end() && !DIt->second.empty())
        Data.FieldDefinitions[ID] = DIt->second;
      auto LIt = LockCounts.find(ID);
      if (LIt != LockCounts.end() && LIt->second != 0)
        Data.LockCounts[ID] = LIt->second;
      // Snapshot the live monitorenter stack so successor blocks see the
      // same path-specific call set we did.
      auto SIt = LiveLockEnters.find(ID);
      if (SIt != LiveLockEnters.end() && !SIt->second.empty())
        Data.LiveLockEnters[ID] = SIt->second;
    } else if (OS->isMaterialized()) {
      Data.Materialized.insert(ID);
    }
  }

  // Eligibility is function-wide within this traversal, but store liveness
  // remains point-sensitive. Preserve ghost reaching definitions after a bail
  // so later blocks and reconvergent merges can still identify which
  // provisional store eliminations a real consumer observes.
  for (const auto &Kv : FieldDefinitions)
    if (!Eligible.lookup(Kv.first) && !Kv.second.empty())
      Data.FieldDefinitions[Kv.first] = Kv.second;

  normalizeIneligibleVirtualRefs(Data);
#ifndef NDEBUG
  assertVirtualReferenceClosure(Data);
#endif
}

void Analyzer::snapshotExitState(BasicBlock *BB) {
  BlockExitInfo Info;
  snapshotExitStateInto(Info);
  BlockExits[BB] = std::move(Info);
}

void Analyzer::deleteOwnedSince(size_t PhiMark, size_t InstMark) {
  // Pop and delete any unparented PHIs/insts added since the marks. The merge
  // only creates unparented PHIs via createUnparentedPhi /
  // getOrCreateLoopFieldPhi's out-of-loop fallback; insertion into a BasicBlock
  // happens in the transform pass, so any value added during a failed merge
  // iteration is still unparented when we discard it. In-loop-cached PHIs (loop
  // headers AND non-header in-loop merge blocks) live in OwnedLoopFieldPhis (a
  // separate bucket) and are intentionally preserved so they stay stable across
  // fixpoint iterations and across per-merge retries. The truncation logic
  // itself is shared with restoreLoopSnapshot via PEAResult::truncateOwnedTo.
  Result.truncateOwnedTo(PhiMark, InstMark);
}

// Classify every Java-heap pointer PHI at BB's entry (see the file header
// for the Case A/B/C classification) and make its merge decision:
//  * Case B — every resolved incoming agrees on one still-virtual ObjectID:
//    register the PHI as a whole-object alias and record it so commit() can
//    erase it if the VO is NeverEscapes.
//  * Case C — resolved incomings are distinct but compatible virtual IDs:
//    synthesizeCaseC builds one synthetic VO merging the per-pred VOs.
//  * Case A — a non-virtual incoming or a Case-C bail: materialize each
//    virtual incoming at its predecessor's terminator.
// Each incoming is resolved against its own predecessor's exit snapshot;
// dead and not-yet-published (unseen backedge) slots are excluded from the
// decision, as are poison wildcards and loop-carried self-references (each
// with its own agreement rule below). CreatePHI effects are routed to Out —
// a retry-cleared buffer during merge fixpoint iterations — and the whole
// decision is re-derived from scratch on every call, so any stale alias on
// the PHI is reset up front.
void Analyzer::processBlockPhis(BasicBlock *BB, jeandle::EffectList &Out) {
  // Walk explicit LLVM PHIs of java-heap pointers. Other PHIs (e.g., scalar
  // i32 PHIs of folded virtual-load results) flow through normal SSA and are
  // not the concern of the analyzer.
  for (PHINode &Phi : BB->phis()) {
    Type *Ty = Phi.getType();
    if (!Ty->isPointerTy())
      continue;
    if (cast<PointerType>(Ty)->getAddressSpace() !=
        jeandle::AddrSpace::JavaHeapAddrSpace)
      continue;

    // Resolve each incoming against its predecessor's exit snapshot. A
    // temporary PEABlockState supplies the predecessor-specific virtual set
    // to the shared identity resolver; AliasMap remains function-wide.
    // Poison is tracked separately as a refinement wildcard. It can agree
    // with a defined Case-B identity only when that object is still virtual
    // on the poison predecessor; it never participates in Case C.
    //
    // An incoming whose predecessor has no exit data yet (a not-yet-visited
    // back edge on the loop fixpoint's first pass, or a killed edge) is
    // UNKNOWN, not a divergence: the MergeProcessor ignores that pred the
    // same way, and an iteration-0 header merge likewise decides on the
    // forward preds only. Deciding on the resolved incomings alone lets
    // iteration 0 take Case B for a loop-carried VO instead of falling to
    // Case A and irreversibly materializing the VO at the preheader (whose
    // exit state lives outside the loop and is never rolled back). The
    // decision is re-derived once the latch's exit data exists: PHI aliases
    // are reset before every merge iteration, and the optimistic path flips
    // no shared state.
    SmallVector<std::optional<jeandle::ObjectID>, 4> InIDs;
    SmallBitVector Unresolved(Phi.getNumIncomingValues(), false);
    SmallBitVector Dead(Phi.getNumIncomingValues(), false);
    SmallBitVector SelfCarry(Phi.getNumIncomingValues(), false);
    SmallBitVector PoisonWildcard(Phi.getNumIncomingValues(), false);
    bool AnyVirtual = false;
    bool AnyDerived = false; // a resolved incoming with a non-zero/non-constant
                             // byte offset (a GEP-with-offset, not the object)
    InIDs.reserve(Phi.getNumIncomingValues());
    for (unsigned I = 0; I < Phi.getNumIncomingValues(); ++I) {
      BasicBlock *Pred = Phi.getIncomingBlock(I);
      Value *V = Phi.getIncomingValue(I);
      std::optional<jeandle::ObjectID> Found;
      EdgeContribution Contribution = contributionFor(Pred, BB);
      if (Contribution.isUnseen()) {
        Unresolved.set(I);
        InIDs.push_back(Found);
        continue;
      }
      if (Contribution.isDead()) {
        Dead.set(I);
        InIDs.push_back(Found);
        continue;
      }
      BlockExitData *PredED = Contribution.Data;
      jeandle::PEABlockState PredState;
      for (jeandle::ObjectID ID : PredED->Virtuals)
        PredState.addObject(ID, jeandle::ObjectState());
      auto BaseIdentity = jeandle::pea::resolveVirtualIdentity(
          V, PredState, Aliases, DL,
          jeandle::pea::VirtualIdentityMode::BaseObject);
      auto WholeIdentity = jeandle::pea::resolveVirtualIdentity(
          V, PredState, Aliases, DL,
          jeandle::pea::VirtualIdentityMode::WholeObject);
      if (WholeIdentity.isPoisonWildcard()) {
        PoisonWildcard.set(I);
      } else if (BaseIdentity.isDefined()) {
        Found = BaseIdentity.getObjectID();
        if (!WholeIdentity.isDefined() || WholeIdentity.getObjectID() != *Found)
          AnyDerived = true;
      } else {
        // Loop-carried self-reference: the incoming value peels (through
        // offset-0 casts / zero-index GEPs / freeze) back to this PHI
        // itself. The virtual alias that would resolve it may not have been
        // registered yet in the current traversal. A self-carry denotes this
        // PHI itself, so it agrees with
        // whatever object the remaining incomings resolve to (verified
        // against the consensus below). A NON-ZERO / non-constant offset on
        // the carry changes the value per iteration — that is a derived
        // carry, not an identity carry.
        int64_t Off = 0;
        bool NonConst = false;
        Value *Base =
            jeandle::pea::stripPointerCastsAndOffsets(V, DL, &Off, &NonConst);
        if (Base == &Phi) {
          SelfCarry.set(I);
          if (NonConst || Off != 0)
            AnyDerived = true;
        }
      }
      // During an ordinary loop body pass, an incoming of the loop-header PHI
      // whose predecessor is inside the loop but has not yet been processed in
      // this pass cannot be trusted as a divergence. First try to re-resolve
      // the incoming through the phi-keyed Case-C cache. If the memo does not
      // cover this slot, the incoming is unknown and the post-body merge
      // re-derives the decision with complete latch data. Restricted to the
      // loop header: non-header blocks get no post-body re-merge, so an
      // optimistic decision there could never be corrected. SelfCarry keeps
      // precedence because it is structural and needs no alias.
      if (!Found && !PoisonWildcard.test(I) && !SelfCarry.test(I) &&
          ActiveBodyPassLoop && BB == ActiveBodyPassLoop->getHeader() &&
          ActiveBodyPassLoop->contains(Pred) &&
          !BodyPassProcessed.count(Pred)) {
        auto MemoIt = CaseCVOCache.find(&Phi);
        if (MemoIt != CaseCVOCache.end() && Eligible.lookup(MemoIt->second)) {
          const jeandle::VirtualObject &MemoVO =
              *Result.VirtualObjects[MemoIt->second];
          if (MemoVO.IsSynthetic && I < MemoVO.SyntheticSourceIDs.size()) {
            jeandle::ObjectID Cand = MemoVO.SyntheticSourceIDs[I];
            if (Cand != jeandle::InvalidObjectID && Eligible.lookup(Cand) &&
                PredED->Virtuals.count(Cand))
              Found = Cand;
          }
        }
        if (!Found)
          Unresolved.set(I);
      }
      InIDs.push_back(Found);
      if (Found)
        AnyVirtual = true;
    }
    // The decision below is re-derived from scratch on every call (each
    // merge iteration, each loop-fixpoint pass, and the fast paths that skip
    // the merge do/while's external alias reset). Clear any stale alias a
    // previous pass left on this PHI — the resolution above already consumed
    // it (a self-referencing back-edge incoming resolves through it), and
    // the cases below re-assign it as needed. Leaving a stale alias in place
    // would both trip addVirtualAlias's uniqueness assert on a repeated
    // Case-B decision and mis-resolve the PHI when the decision flips.
    Aliases.resetAlias(&Phi);
    if (!AnyVirtual)
      continue;

    // Case B: every RESOLVED incoming agrees on the same ObjectID AND the
    // object is still virtual at merge entry (mergeStates kept it).
    // Self-carries are excluded from the consensus scan (they agree with the
    // consensus by construction) and then validated against it: the
    // consensus object must still be virtual at each self-carry pred's exit.
    bool AllSame = true;
    std::optional<jeandle::ObjectID> First;
    for (unsigned I = 0; I < InIDs.size(); ++I) {
      if (Dead[I] || Unresolved[I] || SelfCarry[I] || PoisonWildcard[I])
        continue;
      const auto &O = InIDs[I];
      if (!O) {
        AllSame = false;
        break;
      }
      if (!First)
        First = O;
      else if (*First != *O) {
        AllSame = false;
        break;
      }
    }
    if (AllSame && First)
      for (unsigned I = 0; I < InIDs.size(); ++I) {
        if (Dead[I] || Unresolved[I])
          continue;
        EdgeContribution Contribution =
            contributionFor(Phi.getIncomingBlock(I), BB);
        if ((SelfCarry[I] || PoisonWildcard[I]) &&
            (!Contribution.isLive() ||
             !Contribution.Data->Virtuals.count(*First))) {
          AllSame = false;
          break;
        }
      }

    if (AllSame && First && !AnyDerived) {
      const jeandle::ObjectState *OS =
          CurrentState.getObjectStateOptional(*First);
      if (OS && OS->isVirtual()) {
        // Register the PHI as an alias for the same ObjectID so downstream
        // load/store handlers in this block resolve through it.
        Aliases.addVirtualAlias(&Phi, *First, /*IsWholeObject=*/true);
        // Also record the PHI on the per-VO Case-B alias list so commit() can
        // erase it if the VO is NeverEscapes. The incomings are all the VO's
        // OrigAlloc, which EliminateAllocation RAUWs to poison; the PHI is then
        // dead and we erase it explicitly to avoid a `phi [poison, poison]`
        // artefact past PEA.
        if (!llvm::is_contained(CaseBPhiAliases[*First], &Phi))
          CaseBPhiAliases[*First].push_back(&Phi);
        continue;
      }
    }

    // Case C: every incoming resolves to a virtual ID, but the IDs are not
    // all equal. Attempt to synthesize a single merged VirtualObject. On
    // success the PHI is aliased to the new VO and downstream uses fold
    // through it. On failure (compatibility, identity, or per-entry type
    // checks) we fall through to Case A.
    bool TryCaseC = (First /* at least one virtual */) &&
                    !AllSame; // Case B already returned if AllSame succeeded.
    LLVM_DEBUG(dbgs() << "PEA-PHI-DECIDE: phi '" << Phi.getName() << "' in "
                      << BB->getName() << ": AllSame=" << AllSame
                      << " First=" << (First ? (int)*First : -1)
                      << " AnyDerived=" << AnyDerived
                      << " TryCaseC=" << TryCaseC << "\n");
    if (TryCaseC && !AnyDerived) {
      bool EveryInputVirtual = true;
      {
        unsigned DbgIdx = 0;
        for (auto &O : InIDs) {
          if (Dead[DbgIdx]) {
            ++DbgIdx;
            continue;
          }
          if (Unresolved[DbgIdx]) {
            EveryInputVirtual = false;
            break;
          }
          if (PoisonWildcard[DbgIdx]) {
            EveryInputVirtual = false;
            break;
          }
          if (!O) {
            LLVM_DEBUG(dbgs() << "PEA-PHI-DECIDE: phi '" << Phi.getName()
                              << "' incoming[" << DbgIdx << "] not virtual ("
                              << *Phi.getIncomingValue(DbgIdx) << ")\n");
            EveryInputVirtual = false;
            break;
          }
          DbgIdx++;
        }
      }
      if (EveryInputVirtual && synthesizeCaseC(BB, &Phi, InIDs, Dead, Out))
        continue;
    }

    // Case A: mixed virtual + non-virtual incomings, OR a Case C attempt
    // that bailed. For every virtual incoming, materialize at that
    // incoming's predecessor terminator. The PHI itself stays in IR; each
    // virtual incoming's OrigAlloc use stays unchanged because OrigAlloc is
    // reused post-merge.
    for (unsigned I = 0; I < Phi.getNumIncomingValues(); ++I) {
      if (Dead[I])
        continue;
      if (!InIDs[I])
        continue;
      BasicBlock *Pred = Phi.getIncomingBlock(I);
      EdgeContribution Contribution = contributionFor(Pred, BB);
      if (!Contribution.isLive()) {
        markIneligible(*InIDs[I]);
        continue;
      }
      BlockExitData *PredED = Contribution.Data;
      // Skip if the VO is already materialized for THIS merge. Two cases:
      // (a) a true block-end drain already flipped the shared state (VO no
      // longer virtual in BlockExits[Pred]); (b) an incoming-edge mat for THIS
      // merge (Pred, BB, ID) was already emitted — edge-local replay flips the
      // target view but not the shared predecessor state. Re-firing here would
      // duplicate field and lock replay. An edge mat for a DIFFERENT merge is
      // recorded under (Pred, M2, ID), so the check correctly does NOT skip
      // in that case.
      if (!PredED->Virtuals.count(*InIDs[I]) ||
          isMaterializedAtPred(Pred, BB, *InIDs[I]))
        continue;
      // The PHI consumes this object on one incoming edge. OrigAlloc already
      // supplies the SSA value; materialization replay remains edge-local.
      LLVM_DEBUG(dbgs() << "PEA-CASEA-MAT: phi '" << Phi.getName()
                        << "' incoming[" << I << "] materializes VO="
                        << *InIDs[I] << " at pred " << Pred->getName() << "\n");
      materializeAtPredFromExitInfo(*InIDs[I], Pred, *PredED,
                                    /*EdgeLocal=*/true, MatReason::Phi,
                                    /*TargetMerge=*/BB);

      // Derived carry at the back-edge: the latch PHI's incoming is a GEP /
      // bitcast of the object (not an object-carry). Under reuse-OrigAlloc the
      // per-pred Materialize placed at the latch terminator does NOT dominate
      // the body GEP — but it does not need to, because OrigAlloc is KEPT as
      // the single materialized-value identity for PartiallyEscapes and
      // dominates the body GEP by the SSA invariant (see applyMaterialize's
      // assert that the materialized value equals VObj.AllocationCall). The
      // carrying PHI's incoming is therefore LEFT UNCHANGED; no re-derive
      // effect is emitted. The reuse-OrigAlloc model needs no per-pred
      // pointer re-derivation: OrigAlloc is the materialized value on every
      // edge, so the carry is already sound.
      jeandle::ObjectID OID = *InIDs[I];
      if (!Eligible.lookup(OID))
        continue; // a prior/sibling incoming already made this object
                  // ineligible.
      // A successfully materialized synthetic is represented by its defining
      // SyntheticPhi, not by the AllocationCall borrowed from one source.
      // The incoming therefore already is the correct real identity and must
      // not enter the ordinary derived-from-OrigAlloc validation below.
      if (Result.VirtualObjects[OID]->IsSynthetic) {
        assert(PreparedSyntheticIDs.count(OID) &&
               "eligible synthetic Case-A input must be materialized");
        continue;
      }
      Value *V = Phi.getIncomingValue(I);
      Value *OrigAlloc = Result.VirtualObjects[OID]->AllocationCall;
      if (V == OrigAlloc)
        continue; // object-carry already names the retained allocation.
      int64_t Off = 0;
      bool NonConst = false;
      Value *Base =
          jeandle::pea::stripPointerCastsAndOffsets(V, DL, &Off, &NonConst);
      if (Base != OrigAlloc || NonConst) {
        // Variable-index GEP, or a non-structural alias chain (select/load/PHI
        // embedded in the derivation): cannot soundly re-derive a constant
        // byte offset at the latch. Sound fallback — keep the object real.
        // commit()->dropEffectsForIneligible purges the materialize above (and
        // this would-be effect by mutation owner), so the original allocation
        // survives and no poison leaks.
        markIneligible(OID);
        continue;
      }
      // Under reuse-OrigAlloc, a derived carry (GEP/bitcast of OrigAlloc along
      // the latch PHI) needs no rewrite effect: OrigAlloc is KEPT for
      // PartiallyEscapes and dominates the body GEP, so the GEP stays valid
      // as-is and the carrying PHI's incoming is left unchanged. The
      // per-pred Materialize above (SeqNo strictly less) already carries the
      // materialization; commit()->dropEffectsForIneligible purges it if the
      // object turns ineligible.
      (void)Off;
    }
  }
}

// Case-C legality check for one candidate source object: walk the transitive
// pointer-use graph of the source's identity root (OrigAlloc, or a nested
// synthetic's SyntheticPhi) and decide whether any use observes the source
// identity independently of the merge PHI. Internal uses do not block the
// merge: already-planned effects of this VO, field accesses through
// offset-resolvable derivations, deopt references that cannot observe the
// collapsed identity, transparent carrier PHIs of the (transitively closed)
// Case-C group, and anything reached only by crossing the Case-C PHI — such
// a use observes the merged identity the PHI legitimately represents on
// every path, and the synthetic is materialized at that use downstream.
// Equality compares not decided by allocation-site distinctness, leaks,
// selects, and opaque derivations reached from a source root observe the
// source identity: return true. A virtual field of another object still
// holding this ID observes it too.
bool Analyzer::hasObservableIdentityUse(
    jeandle::ObjectID ID, PHINode *CaseCPhi,
    ArrayRef<BlockExitData *> ExitInfos,
    ArrayRef<jeandle::ObjectID> CaseCSourceIDs) {
  jeandle::VirtualObject &VO = *Result.VirtualObjects[ID];
  CallBase *OrigAlloc = cast_or_null<CallBase>((Value *)VO.AllocationCall);
  Value *IdentityRoot = VO.IsSynthetic ? static_cast<Value *>(VO.SyntheticPhi)
                                       : static_cast<Value *>(OrigAlloc);
  auto *IdentityDef = dyn_cast_or_null<Instruction>(IdentityRoot);
  if (!IdentityRoot || !IdentityDef)
    return true;

  DenseSet<Instruction *> InternalTargets;
  ensureEffectsByOwnerCache();
  auto OwnerIt = EffectsByOwnerCache.find(ID);
  if (OwnerIt != EffectsByOwnerCache.end())
    for (const jeandle::Effect *E : OwnerIt->second)
      if (Instruction *Target = E->getTarget())
        // A folded identity compare records the icmp as an effect target,
        // but the compare still observes this VO's identity: the fold is
        // valid only while the VO keeps a distinct identity, so Case C must
        // still be refused when identity is observed. Keep icmps visible
        // to the walk below.
        if (!isa<ICmpInst>(Target))
          InternalTargets.insert(Target);

  // The Case-C group, transitively closed through synthetic sources: a
  // nested synthetic's own sources belong to the same identity flow, so a
  // carrier PHI may route them as well (loop-carried replacement: the
  // header Case C merges [VO0, S] where the join synthetic S covers
  // [VO1, VO0]; the join PHI carrying VO1 is then a transparent carrier
  // for the header merge too).
  SmallDenseSet<jeandle::ObjectID, 8> CaseCGroup(CaseCSourceIDs.begin(),
                                                 CaseCSourceIDs.end());
  {
    SmallVector<jeandle::ObjectID, 8> GroupWorklist(CaseCSourceIDs.begin(),
                                                    CaseCSourceIDs.end());
    while (!GroupWorklist.empty()) {
      jeandle::ObjectID G = GroupWorklist.pop_back_val();
      const jeandle::VirtualObject &GVO = *Result.VirtualObjects[G];
      if (!GVO.IsSynthetic)
        continue;
      for (jeandle::ObjectID S : GVO.SyntheticSourceIDs)
        if (S != jeandle::InvalidObjectID && CaseCGroup.insert(S).second)
          GroupWorklist.push_back(S);
    }
  }

  // LLVM has explicit pointer-derivation instructions between an identity
  // root and its consumers. The root is OrigAlloc for an ordinary VO and its
  // defining SyntheticPhi for a nested Case-C VO. Follow every
  // alias-preserving derivation with a known byte offset so a later identity
  // use cannot hide behind a zero-GEP/freeze chain. Constant non-zero
  // derivations are followed as access paths: they are harmless only when
  // every leaf is a planned virtual load/store effect. Symbolic offsets are
  // opaque and therefore observing. PHIs are merge points, not wrappers;
  // the Case-C PHI and carrier PHIs whose incomings all belong to the
  // (transitive) Case-C group are traversed through to their consumers.
  SmallVector<Value *, 8> Worklist(1, IdentityRoot);
  SmallPtrSet<Value *, 16> Visited;
  // Values that denote the group's merged identity without carrying a
  // registered alias at walk time: the Case-C PHI itself plus every carrier
  // PHI the walk pushed as transparent. During an in-pass header merge the
  // carrier's own alias (registered later in the same pass, or in a block
  // outside the loop) is not yet available, so structural recognition must
  // go through this set. Field-address derivations of these values are
  // internal access paths, not identity observations.
  SmallPtrSet<Value *, 8> GroupCarriers;
  GroupCarriers.insert(CaseCPhi);
  // The identity root denotes this source by construction; its alias may be
  // unavailable mid-merge (a synthetic's SyntheticPhi registered later in
  // the pass), so root derivations must be recognized structurally.
  GroupCarriers.insert(IdentityRoot);
  // Values reached by crossing the Case-C PHI (or a carrier of it). A use
  // reached from one of these observes the MERGED identity — the Case-C PHI
  // is itself the real per-path identity of the merged object, so the use
  // is sound under the merge: downstream processing materializes the
  // synthetic at that use. A use reached directly from a source root (never
  // crossing the phi) observes the SOURCE identity independently and must
  // block the merge.
  SmallPtrSet<Value *, 16> CrossedMerge;
  CrossedMerge.insert(CaseCPhi);
  // Decides whether a pointer PHI routes only Case-C group identities:
  // every incoming is the CaseCPhi, the PHI itself, a group member (alias),
  // an already-recognized carrier, an offset-0 wrapper of a source VO's
  // identity root, or (recursively) another transparent carrier PHI.
  // Recursive because a carrier chain may route the group through several
  // PHIs (nested loops: outer header phi via outer latch phi via join phi),
  // and a not-yet-aliased carrier's transparency can only be decided from
  // its own incomings. A cycle back to a PHI already being evaluated is
  // transparent (it routes the group's own identity around); any non-group
  // incoming is still found on its own path.
  SmallPtrSet<PHINode *, 8> CarrierEvalStack;
  std::function<bool(PHINode *)> IsTransparentCarrier =
      [&](PHINode *P) -> bool {
    for (unsigned I = 0, E = P->getNumIncomingValues(); I < E; ++I) {
      Value *IV = P->getIncomingValue(I);
      if (IV == P || IV == CaseCPhi)
        continue;
      auto IAID = Aliases.getVirtualAlias(IV);
      if (IAID && CaseCGroup.count(*IAID))
        continue;
      if (GroupCarriers.count(IV))
        continue;
      if (auto *IPhi = dyn_cast<PHINode>(IV)) {
        if (!CarrierEvalStack.insert(IPhi).second)
          continue; // carrier cycle: routes the group's own identity.
        bool Sub = IsTransparentCarrier(IPhi);
        CarrierEvalStack.erase(IPhi);
        if (Sub) {
          GroupCarriers.insert(IPhi);
          continue;
        }
      } else {
        int64_t IOff = 0;
        bool INonConst = false;
        Value *IBase = jeandle::pea::stripPointerCastsAndOffsets(IV, DL, &IOff,
                                                                 &INonConst);
        if (!INonConst && IOff == 0) {
          bool IsSourceRoot = false;
          for (jeandle::ObjectID SID : CaseCGroup) {
            const jeandle::VirtualObject &SVO = *Result.VirtualObjects[SID];
            Value *SRoot = SVO.IsSynthetic
                               ? static_cast<Value *>(SVO.SyntheticPhi)
                               : static_cast<Value *>(SVO.AllocationCall);
            if (IBase == SRoot) {
              IsSourceRoot = true;
              break;
            }
          }
          if (IsSourceRoot)
            continue;
        }
      }
      LLVM_DEBUG(dbgs() << "PEA-CASEC-BAIL: carrier phi '" << P->getName()
                        << "' not transparent for VO=" << ID << "; incoming '"
                        << IV->getName() << "' not in Case-C group\n");
      return false;
    }
    return true;
  };
  while (!Worklist.empty()) {
    Value *Current = Worklist.pop_back_val();
    if (!Visited.insert(Current).second)
      continue;
    for (Use &Use : Current->uses()) {
      User *U = Use.getUser();
      // The Case-C PHI itself routes the source identity into the merged
      // object; it is a transparent carrier by construction (its incomings
      // are exactly the Case-C group). Traverse THROUGH it: an
      // identity-observing consumer of the PHI's result (an
      // identity-dependent equality compare, a leak) observes the merged
      // identity of every source, while field accesses and further
      // carrier PHIs remain internal.
      if (U == CaseCPhi) {
        Worklist.push_back(U);
        continue;
      }
      auto *UI = dyn_cast<Instruction>(U);
      if (!UI)
        return true;
      // A frame-state reference at a safepoint that cannot execute after this
      // merge observes the source object only on its original predecessor
      // path. It is a virtual mapping of the source, not a use of the
      // collapsed identity. A deopt operand at or after the Case-C PHI
      // remains observable: reconstruction could otherwise expose the source
      // and the synthetic object simultaneously.
      if (auto *CB = dyn_cast<CallBase>(UI)) {
        unsigned Operand = Use.getOperandNo();
        if (CB->isBundleOperand(Operand) &&
            CB->getOperandBundleForOperand(Operand).isDeoptOperandBundle()) {
          // A safepoint in the identity definition's own block, after the
          // definition, references the CURRENT dynamic instance of the
          // identity (a virtual mapping of that instance): every path from
          // the Case-C PHI to it passes through the definition. Handle this
          // case explicitly — isPotentiallyReachable reports "reachable" when
          // the target sits inside the excluded block, because it checks
          // the stop set before the exclusion set.
          if (CB->getParent() == IdentityDef->getParent() &&
              IdentityDef->comesBefore(CB))
            continue;
          // In a loop, the safepoint can be CFG-reachable from this PHI only
          // after executing the identity definition again, in which case it
          // describes the next dynamic identity rather than the one collapsed
          // here. Excluding the definition block models that barrier.
          SmallPtrSet<BasicBlock *, 1> AllocationBarrier;
          AllocationBarrier.insert(IdentityDef->getParent());
          if (!isPotentiallyReachable(CaseCPhi, CB, &AllocationBarrier, &DT,
                                      &LI))
            continue;
        }
      }
      if (InternalTargets.count(UI))
        continue;

      // A load/store whose POINTER operand is a field-address derivation of
      // any Case-C group member (or the Case-C PHI itself) is a field access
      // of the merged object, not an identity observation. (A use as a
      // store's VALUE operand publishes the identity instead — that is not
      // a field access of this object and falls through to the observation
      // checks below.) The derivation may sit in a block not yet processed
      // (e.g. a loop exit analyzed after the loop fixpoint), so neither an
      // effect nor an alias is registered for it yet — resolve the pointer
      // structurally.
      Value *AccessPtr = nullptr;
      if (auto *Ld = dyn_cast<LoadInst>(UI))
        AccessPtr = Ld->getPointerOperand();
      else if (auto *St = dyn_cast<StoreInst>(UI))
        AccessPtr = St->getPointerOperand();
      if (AccessPtr && AccessPtr == Current) {
        int64_t FSOff = 0;
        bool FSNonConst = false;
        Value *FSBase = jeandle::pea::stripPointerCastsAndOffsets(
            AccessPtr, DL, &FSOff, &FSNonConst);
        if (!FSNonConst) {
          auto BaseAlias = Aliases.getVirtualAlias(FSBase);
          if (GroupCarriers.count(FSBase) ||
              (BaseAlias && CaseCGroup.count(*BaseAlias)))
            continue;
        }
      }

      // An equality compare observes runtime identity unless its result is
      // fixed by allocation-site distinctness. The compare is
      // identity-dependent iff the OTHER operand may denote a member of the
      // Case-C group at runtime: unresolvable (e.g. a carried PHI whose
      // alias is reset mid-merge), or resolving into the (transitive)
      // group. A null check is identity-independent (virtuals are
      // non-null), and a compare against a provably different ordinary VO
      // or a non-virtual pointer stays constant whether or not Case C
      // fires, so a folded result there remains sound.
      if (auto *II = dyn_cast<ICmpInst>(UI)) {
        if (II->isEquality()) {
          Value *Other = II->getOperand(0) == Current ? II->getOperand(1)
                                                      : II->getOperand(0);
          if (isa<ConstantPointerNull>(Other))
            continue;
          auto OtherID =
              jeandle::pea::resolveVirtualRef(Other, CurrentState, Aliases, DL);
          if (!OtherID || CaseCGroup.count(*OtherID))
            return true;
          continue;
        }
        return true;
      }

      // A pointer PHI may route the source identity onward — to the Case-C
      // merge, around a loop back-edge, or to field accesses — without
      // introducing a new identity. Two crossing rules apply:
      //  * Reached ACROSS the Case-C merge point (Current is the Case-C PHI
      //    or a value already crossed): always cross. The PHI consumes the
      //    merged identity; whatever its other incomings are (an external
      //    pointer, another VO), downstream merge handling covers them
      //    (mixed state materializes the synthetic there, or a nested Case
      //    C re-merges it), exactly as if the merged object were the
      //    original per-path allocation.
      //  * Reached directly from a source root: cross only when every
      //    incoming routes a group identity (IsTransparentCarrier), i.e.
      //    the PHI is identity-preserving for the group. Its consumers
      //    then observe the SOURCE identity — leaks and identity compares
      //    there must still block the merge: any use of a source identity
      //    other than routing it into the Case-C PHI would collapse two
      //    distinct runtime identities into one.
      // The PHI's own alias is not consulted: a carrier in a block
      // processed later (e.g. the outer loop's latch during a nested loop's
      // Case C) has no alias registered yet, and a carrier's alias (when
      // present) denotes only one group member while the PHI may route the
      // whole group.
      if (auto *CarrierPhi = dyn_cast<PHINode>(UI)) {
        if (CrossedMerge.count(Current) || IsTransparentCarrier(CarrierPhi)) {
          GroupCarriers.insert(UI);
          if (CrossedMerge.count(Current))
            CrossedMerge.insert(UI);
          Worklist.push_back(UI);
          continue;
        }
        return true;
      }

      auto AliasID = Aliases.getVirtualAlias(UI);
      if (!AliasID || !CaseCGroup.count(*AliasID)) {
        // A field-access GEP/BitCast in a block not yet processed (e.g. a
        // loop exit, analyzed after the loop fixpoint) may not have its own
        // alias registered yet. Resolve through its pointer operand: if the
        // operand denotes the Case-C PHI or aliases to a group member
        // (directly or via an offset-0 wrapper), this use is a field-access
        // derivation, not an identity observer.
        Value *Operand = nullptr;
        if (auto *GEP = dyn_cast<GEPOperator>(UI))
          Operand = GEP->getPointerOperand();
        else if (auto *BC = dyn_cast<BitCastOperator>(UI))
          Operand = BC->getOperand(0);
        else if (auto *AC = dyn_cast<AddrSpaceCastOperator>(UI))
          Operand = AC->getOperand(0);
        else if (auto *FI = dyn_cast<FreezeInst>(UI))
          Operand = FI->getOperand(0);
        else if (auto *II = dyn_cast<IntrinsicInst>(UI)) {
          Intrinsic::ID IID = II->getIntrinsicID();
          if (IID == Intrinsic::launder_invariant_group ||
              IID == Intrinsic::strip_invariant_group ||
              IID == Intrinsic::ptr_annotation)
            Operand = II->getArgOperand(0);
        }
        if (Operand == CaseCPhi || GroupCarriers.count(Operand)) {
          AliasID = ID;
        } else if (Operand) {
          auto OpAlias = Aliases.getVirtualAlias(Operand);
          if (!OpAlias) {
            int64_t TOff = 0;
            bool TNonConst = false;
            Value *TBase = jeandle::pea::stripPointerCastsAndOffsets(
                Operand, DL, &TOff, &TNonConst);
            OpAlias = Aliases.getVirtualAlias(TBase);
          }
          if (OpAlias && CaseCGroup.count(*OpAlias))
            AliasID = OpAlias;
        }
        if (!AliasID || !CaseCGroup.count(*AliasID)) {
          // A use reached by crossing the Case-C PHI observes the merged
          // identity, which the PHI itself legitimately represents on every
          // path; the merge may proceed and the synthetic is materialized
          // at this use downstream.
          if (CrossedMerge.count(Current))
            continue;
          LLVM_DEBUG(dbgs() << "PEA-CASEC-BAIL: identity walk sees user ";
                     UI->print(dbgs());
                     dbgs() << " with alias=" << (AliasID ? (int)*AliasID : -1)
                            << " (want VO=" << ID << ", isaPHI="
                            << (isa<PHINode>(UI) ? 1 : 0) << ")\n");
          return true;
        }
      }
      // A select on the source identity is an observation (the per-arm
      // identities cannot be tracked through it) — unless the select is
      // reached across the Case-C PHI, where it consumes the merged
      // identity and is materialized downstream.
      if (isa<SelectInst>(UI)) {
        if (CrossedMerge.count(Current))
          continue;
        return true;
      }

      // Instruction-form ptrtoint is deliberately not transparent here: the
      // normal instruction dispatch treats the integer value as an identity
      // observation and materializes the virtual before a later inttoptr can
      // form a same-width round-trip. PartialEscapeUtils can structurally peel
      // a pre-existing round-trip for identity/offset consistency, but that is
      // not a promise to keep a virtual object live across PtrToIntInst.
      bool Traceable = isa<GEPOperator>(UI) || isa<BitCastOperator>(UI) ||
                       isa<AddrSpaceCastOperator>(UI) || isa<FreezeInst>(UI);
      if (auto *II = dyn_cast<IntrinsicInst>(UI)) {
        Intrinsic::ID IID = II->getIntrinsicID();
        Traceable = IID == Intrinsic::launder_invariant_group ||
                    IID == Intrinsic::strip_invariant_group ||
                    IID == Intrinsic::ptr_annotation;
      }
      std::optional<int64_t> Offset = jeandle::pea::resolveFieldOffset(UI, DL);
      if (!Traceable || !Offset) {
        if (CrossedMerge.count(Current))
          continue; // observes the merged identity; materialized downstream.
        return true;
      }
      if (CrossedMerge.count(Current))
        CrossedMerge.insert(UI);
      Worklist.push_back(UI);
    }
  }

  // No other virtual object may retain this source identity in a virtual
  // field. Include both predecessor snapshots and the live analyzer state:
  // an object synthesized earlier in the same merge iteration exists only in
  // the latter until the block exit is snapshotted.
  for (BlockExitData *ExitInfo : ExitInfos)
    for (auto &KV : ExitInfo->FieldStates) {
      if (KV.first == ID)
        continue;
      for (auto &Off : KV.second)
        if (Off.second.isVirtualRef() && Off.second.getVirtualRef() == ID)
          return true;
    }
  for (auto &KV : FieldStates) {
    if (KV.first == ID)
      continue;
    for (auto &Off : KV.second)
      if (Off.second.isVirtualRef() && Off.second.getVirtualRef() == ID)
        return true;
  }
  return false;
}

// Case C: build one synthetic VirtualObject that merges the distinct
// per-pred VOs of a pointer PHI. Pipeline: compatibility checks (kind,
// klass, array shape; lock counts and (Call, BytecodeDepth) live-enter
// stacks; no self-loop incoming; no observable source identity via
// hasObservableIdentityUse); an OffsetPlan precompute over the union of
// per-pred field offsets (merged PHI type, per-pred FieldValues, AllSame
// detection), done BEFORE the VO is created so a type-mismatch bail leaves
// Result.VirtualObjects unchanged; per-pred materialization of VirtualRef
// inners on the corresponding incoming edges; per-offset CreatePHI emission
// into Out for disagreeing offsets. On success the merge PHI is registered
// as a whole-object alias of the synthetic VO, and the merged field state
// takes the PHI (or the sole value where all preds agree). Returns false on
// any incompatibility; bails after VO creation poison the new ID so the
// half-built VO is never observable. In-loop merges cache the synthetic VO
// by PHI so the ObjectID and per-offset PHI shells stay stable across
// loop-fixpoint iterations.
bool Analyzer::synthesizeCaseC(BasicBlock *BB, PHINode *Phi,
                               ArrayRef<std::optional<jeandle::ObjectID>> InIDs,
                               const SmallBitVector &Dead,
                               jeandle::EffectList &Out) {
  // TODO(ensure-virtualized): when an EnsureVirtualized bit lands on
  // ObjectState, downgrade it here per-pred (Graal setEnsureVirtualized(false)
  // where not all preds agree). Differing VirtualRef fields below still route
  // their child materializations through materializeAtPredFromExitInfo.
  const unsigned OriginalN = Phi->getNumIncomingValues();
  assert(InIDs.size() == OriginalN && Dead.size() == OriginalN);

  // Resolve Live VO ids, predecessor blocks, and their exit snapshots while
  // retaining each original PHI slot. Dead slots carry InvalidObjectID in the
  // synthetic metadata until CFG cleanup removes the matching PHI incoming.
  SmallVector<jeandle::ObjectID, 4> PerPredIDs;
  PerPredIDs.reserve(OriginalN);
  SmallVector<BasicBlock *, 4> Preds;
  Preds.reserve(OriginalN);
  SmallVector<BlockExitData *, 4> ExitInfos;
  ExitInfos.reserve(OriginalN);
  SmallVector<unsigned, 4> PerPredOriginalIndices;
  SmallVector<jeandle::ObjectID, 4> SourceIDsByOriginal(
      OriginalN, jeandle::InvalidObjectID);
  for (unsigned i = 0; i < OriginalN; ++i) {
    if (Dead[i])
      continue;
    if (!InIDs[i])
      return false;
    PerPredIDs.push_back(*InIDs[i]);
    PerPredOriginalIndices.push_back(i);
    SourceIDsByOriginal[i] = *InIDs[i];
    BasicBlock *P = Phi->getIncomingBlock(i);
    Preds.push_back(P);
    EdgeContribution Contribution = contributionFor(P, BB);
    if (!Contribution.isLive())
      return false;
    ExitInfos.push_back(Contribution.Data);
    // Each per-pred VO must be eligible AND still virtual at pred exit.
    if (!Eligible.lookup(PerPredIDs.back()))
      return false;
    if (!ExitInfos.back()->Virtuals.count(PerPredIDs.back()))
      return false;
  }
  const unsigned LiveN = PerPredIDs.size();
  if (LiveN == 0)
    return false;

  // Compatibility check.
  LLVM_DEBUG({
    dbgs() << "PEA-CASEC-ENTRY: merge " << BB->getName() << ":";
    for (unsigned i = 0; i < LiveN; ++i)
      dbgs() << " [VO=" << PerPredIDs[i] << "@" << Preds[i]->getName()
             << " elig=" << (Eligible.lookup(PerPredIDs[i]) ? 1 : 0) << " virt="
             << (ExitInfos[i]->Virtuals.count(PerPredIDs[i]) ? 1 : 0) << "]";
    dbgs() << "\n";
  });
  jeandle::VirtualObject &Ref = *Result.VirtualObjects[PerPredIDs[0]];
  for (unsigned i = 1; i < LiveN; ++i) {
    jeandle::VirtualObject &VO = *Result.VirtualObjects[PerPredIDs[i]];
    if (VO.getKind() != Ref.getKind())
      return false;
    if (VO.Klass != Ref.Klass)
      return false;
    if (Ref.isArray()) {
      if (VO.ArrayElementType != Ref.ArrayElementType)
        return false;
      if (VO.ArrayLength != Ref.ArrayLength)
        return false;
      if (VO.ArrayIndexScale != Ref.ArrayIndexScale)
        return false;
      if (VO.ArrayBaseOffset != Ref.ArrayBaseOffset)
        return false;
    }
  }

  // Lock compatibility: the per-pred live lock counts must match.
  unsigned RefLC = ExitInfos[0]->LockCounts.lookup(PerPredIDs[0]);
  for (unsigned i = 1; i < LiveN; ++i) {
    if (ExitInfos[i]->LockCounts.lookup(PerPredIDs[i]) != RefLC)
      return false;
  }
  if (RefLC != 0) {
    const auto &RefStack = ExitInfos[0]->LiveLockEnters.lookup(PerPredIDs[0]);
    for (unsigned i = 1; i < LiveN; ++i) {
      const auto &S = ExitInfos[i]->LiveLockEnters.lookup(PerPredIDs[i]);
      if (S.size() != RefStack.size())
        return false;
      // Two stacks built from the same call sites but at different bytecode
      // depths must NOT be collapsed by the Case-C identity-merge fast path,
      // so compare Call AND the stable CFG-derived BytecodeDepth.
      for (unsigned k = 0; k < S.size(); ++k)
        if (S[k].Call != RefStack[k].Call ||
            S[k].BytecodeDepth != RefStack[k].BytecodeDepth)
          return false;
    }
  }

  // Early-bail if any incoming of Phi equals Phi itself (a
  // back-edge self-reference on a loop-header PHI). A self-loop incoming
  // means the per-pred VO this slot resolves to is one that we're about
  // to synthesise *into* — there is no per-pred independent allocation
  // and the identity check cannot meaningfully proceed.
  for (unsigned OriginalIndex : PerPredOriginalIndices) {
    if (Phi->getIncomingValue(OriginalIndex) == Phi)
      return false;
  }

  // Every VO has identity. Case C replaces each source identity with the
  // merged one, so no source identity may be observable anywhere else first.
  // LLVM aliases are explicit SSA instructions, so the rule is applied to
  // the transitive pointer-use graph rather than only to OrigAlloc's direct
  // users.
  for (unsigned i = 0; i < LiveN; ++i) {
    jeandle::ObjectID PID = PerPredIDs[i];
    if (hasObservableIdentityUse(PID, Phi, ExitInfos, PerPredIDs)) {
      LLVM_DEBUG(dbgs() << "PEA-CASEC-BAIL: identity observed for VO=" << PID
                        << " at merge " << BB->getName() << "\n");
      return false;
    }
  }

  // In-loop cache lookup, keyed by the merge PHI.
  // The cache covers ANY in-loop merge block, not just loop headers (same
  // reach as LoopFieldPhiCache): a non-header in-loop merge that synthesized
  // a fresh VO every fixpoint iteration would never converge — each
  // iteration's BlockExits would carry a different ObjectID, so the
  // exit-state equivalence check never reports equality and the fixpoint
  // burns through every retry into MATERIALIZE_ALL.
  //
  // Peek the cache for an already-synthesised VO for this PHI. On a hit we
  // fall through into the full synthesize path reusing CachedExistingID as
  // the ObjectID (rather than returning early), so FieldStates[Cached] is
  // repopulated each iteration from the CURRENT per-pred exits — the source
  // set may have evolved since the entry was created; the hit only fixes the
  // ObjectID. The PHI emission below uses getOrCreateLoopFieldPhi so
  // per-offset PHI shells (and FieldStates' Value*) stay stable across
  // iterations.
  bool InLoop = LI.getLoopFor(BB) != nullptr;
  jeandle::ObjectID CachedExistingID = jeandle::InvalidObjectID;
  if (InLoop) {
    auto CIt = CaseCVOCache.find(Phi);
    if (CIt != CaseCVOCache.end()) {
      jeandle::ObjectID Cached = CIt->second;
      if (Eligible.lookup(Cached))
        CachedExistingID = Cached;
      // If the cached ID was made ineligible (e.g. materialized in a previous
      // top-level pass), fall through and synthesize a fresh VO; the insert
      // below overwrites the stale entry.
    }
  }

  // Pre-flight: compute per-entry merged type and per-pred input values for
  // every offset in the union of per-pred FieldStates. We do this BEFORE
  // creating the new VO so a type-mismatch bail leaves Result.VirtualObjects
  // unchanged.
  DenseSet<int64_t> OffsetsSet;
  for (unsigned i = 0; i < LiveN; ++i) {
    auto FIt = ExitInfos[i]->FieldStates.find(PerPredIDs[i]);
    if (FIt == ExitInfos[i]->FieldStates.end())
      continue;
    for (auto &Kv : FIt->second)
      OffsetsSet.insert(Kv.first);
  }
  SmallVector<int64_t, 8> Offsets(OffsetsSet.begin(), OffsetsSet.end());
  llvm::sort(Offsets);

  struct OffsetPlan {
    int64_t Off;
    Type *PhiType = nullptr;
    bool AllSame = true;
    jeandle::FieldValue SoleValue;
    SmallVector<jeandle::FieldValue, 4> PerPredFVs;
  };
  SmallVector<OffsetPlan, 8> Plans;
  Plans.reserve(Offsets.size());

  for (int64_t Off : Offsets) {
    OffsetPlan P;
    P.Off = Off;
    P.PerPredFVs.resize(LiveN);
    Type *PhiType = nullptr;
    bool AllPointer = true;
    for (unsigned i = 0; i < LiveN; ++i) {
      jeandle::FieldValue FV = jeandle::FieldValue::unknown();
      auto FIt = ExitInfos[i]->FieldStates.find(PerPredIDs[i]);
      if (FIt != ExitInfos[i]->FieldStates.end()) {
        auto OIt = FIt->second.find(Off);
        if (OIt != FIt->second.end())
          FV = OIt->second;
      }
      P.PerPredFVs[i] = FV;
      if (FV.isUnknown())
        continue;
      Type *T =
          FV.isScalar() ? FV.getScalar()->getType() : FV.getDeclaredType();
      if (!T)
        return false;
      if (!T->isPointerTy() ||
          T->getPointerAddressSpace() != jeandle::AddrSpace::JavaHeapAddrSpace)
        AllPointer = false;
      if (!PhiType)
        PhiType = T;
      else if (PhiType != T && !(PhiType->isPointerTy() && T->isPointerTy() &&
                                 PhiType->getPointerAddressSpace() ==
                                     jeandle::AddrSpace::JavaHeapAddrSpace &&
                                 T->getPointerAddressSpace() ==
                                     jeandle::AddrSpace::JavaHeapAddrSpace))
        return false;
    }
    if (!PhiType)
      continue; // every pred has this slot unknown — nothing to record.
    if (AllPointer)
      PhiType = PointerType::get(F.getContext(),
                                 jeandle::AddrSpace::JavaHeapAddrSpace);
    P.PhiType = PhiType;
    // Detect AllSame across preds (shallowEquals comparison).
    jeandle::FieldValue First = P.PerPredFVs[0];
    P.SoleValue = First;
    bool Same = true;
    for (unsigned i = 1; i < LiveN; ++i)
      if (!First.shallowEquals(P.PerPredFVs[i])) {
        Same = false;
        break;
      }
    P.AllSame = Same && !First.isUnknown();
    Plans.push_back(std::move(P));
  }

  DenseMap<int64_t, FieldDefinitionSet> MergedDefinitions;
  for (int64_t Off : Offsets) {
    FieldDefinitionSet &Defs = MergedDefinitions[Off];
    for (unsigned I = 0; I < LiveN; ++I) {
      auto DIt = ExitInfos[I]->FieldDefinitions.find(PerPredIDs[I]);
      if (DIt == ExitInfos[I]->FieldDefinitions.end())
        continue;
      auto OIt = DIt->second.find(Off);
      if (OIt == DIt->second.end())
        continue;
      Defs.insert(OIt->second.begin(), OIt->second.end());
    }
    if (Defs.empty())
      MergedDefinitions.erase(Off);
  }

  // A differing VirtualRef field requires materializing each referenced
  // object on the corresponding incoming edge before the merged field PHI is
  // created.  Preflight every such edge before emitting any child
  // materialization: if one edge is unsplittable, retaining only a prefix of
  // the children would leave a half-committed Case-C plan.  Keep the complete
  // owner/child group real instead.
  bool UnsupportedVirtualRefEdge = false;
  for (const OffsetPlan &P : Plans) {
    if (P.AllSame)
      continue;
    for (unsigned I = 0; I < LiveN; ++I)
      if (P.PerPredFVs[I].isVirtualRef() &&
          !isReplayEdgeSupported(Preds[I], BB))
        UnsupportedVirtualRefEdge = true;
  }
  if (UnsupportedVirtualRefEdge) {
    for (jeandle::ObjectID ID : PerPredIDs)
      markIneligible(ID, /*FreshRetry=*/true);
    for (const OffsetPlan &P : Plans)
      for (const jeandle::FieldValue &FV : P.PerPredFVs)
        if (FV.isVirtualRef())
          markIneligible(FV.getVirtualRef(), /*FreshRetry=*/true);
    return false;
  }

  // Synthesize (or REUSE on cache hit) the new VirtualObject. On a
  // cache hit we reuse the existing ID (and existing VirtualObjects slot)
  // and merely refresh its synthetic metadata. On a miss we duplicate Ref,
  // allocate a fresh ID via createVirtualObject, and tag it synthetic.
  jeandle::ObjectID NewID;
  if (CachedExistingID != jeandle::InvalidObjectID) {
    NewID = CachedExistingID;
    jeandle::VirtualObject &VO = *Result.VirtualObjects[NewID];
    VO.IsSynthetic = true;
    VO.SyntheticSourceIDs.assign(SourceIDsByOriginal.begin(),
                                 SourceIDsByOriginal.end());
    VO.SyntheticPhi = Phi;
  } else {
    auto NewVOUP = Ref.duplicate();
    NewID = Result.createVirtualObject(std::move(NewVOUP));
    jeandle::VirtualObject &NewVO = *Result.VirtualObjects[NewID];
    NewVO.IsSynthetic = true;
    NewVO.SyntheticSourceIDs.assign(SourceIDsByOriginal.begin(),
                                    SourceIDsByOriginal.end());
    NewVO.SyntheticPhi = Phi;
  }
  // Note: NewVO.AllocationCall is shared with Ref (the first per-pred VO).
  // It MUST NOT be used as a Materialize target or for RAUW. SyntheticPhi is
  // the replay receiver; AllocationCall remains non-null only because
  // structural accessors shared with ordinary VOs expect it.

  // Rebuild the synthetic VO's Fields as the UNION of every per-pred VO's
  // Fields. duplicate() only copied Ref's (pred-0's) Fields, but the merged
  // FieldStates we build below spans the union of all preds' stored offsets.
  // A later sub-slot / wider load against the merged object scans VObj.Fields
  // to find the containing slot (processLoad); if a FieldDesc that came only
  // from a non-pred-0 path were missing, the scan would find nothing and the
  // load would silently fold to the default zero instead of the merged value.
  // getOrCreateFieldIndex is idempotent on exact matches (safe on the cached
  // loop-header VO and for Ref's already-present fields) and returns -1 on an
  // overlap/size conflict, which we treat as an incompatibility bail — exactly
  // like the type-mismatch bails in the Plans loop below. We poison NewID
  // before returning so the half-built VO is never observable; no PHI effects
  // have been committed at this point.
  {
    jeandle::VirtualObject &MergedVO = *Result.VirtualObjects[NewID];
    for (unsigned i = 0; i < LiveN; ++i) {
      const jeandle::VirtualObject &PVO = *Result.VirtualObjects[PerPredIDs[i]];
      for (const auto &FD : PVO.Fields) {
        if (MergedVO.getOrCreateFieldIndex(FD.Offset, FD.LLVMType, DL) < 0) {
          Eligible[NewID] = false;
          return false;
        }
      }
    }
  }

  // Materialize inner virtuals if any per-pred entry is a VirtualRef. This
  // happens BEFORE we emit CreatePHI effects so the PHI inputs point at each
  // inner VO's real identity (OrigAlloc or SyntheticPhi). Any failure here
  // marks the VO ineligible and returns false; the per-entry CreatePHI effects
  // we add below (for NewID) get dropped at commit. Inner materializations may
  // have side-effects on snapshot state, but those are independently sound.
  DenseMap<int64_t, jeandle::FieldValue> Merged;
  jeandle::EffectList PendingPhiEffects;

  for (const OffsetPlan &P : Plans) {
    if (P.AllSame) {
      Merged[P.Off] = P.SoleValue;
      continue;
    }
    // Compute per-pred Value* for the synthesized PHI.
    SmallVector<Value *, 4> InValues;
    InValues.reserve(LiveN);
    for (unsigned i = 0; i < LiveN; ++i) {
      const jeandle::FieldValue &FV = P.PerPredFVs[i];
      Value *In = nullptr;
      if (FV.isUnknown()) {
        In = jeandle::FieldValue::defaultFor(P.PhiType);
      } else if (FV.isScalar()) {
        Value *V = FV.getScalar();
        if (V->getType() != P.PhiType) {
          Eligible[NewID] = false;
          return false;
        }
        In = V;
      } else if (FV.isMaterializedRef()) {
        if (!P.PhiType->isPointerTy()) {
          Eligible[NewID] = false;
          return false;
        }
        In = FV.getMaterialized();
      } else if (FV.isVirtualRef()) {
        if (!P.PhiType->isPointerTy()) {
          Eligible[NewID] = false;
          return false;
        }
        jeandle::ObjectID InnerID = FV.getVirtualRef();
        materializeAtPredFromExitInfo(InnerID, Preds[i], *ExitInfos[i],
                                      /*EdgeLocal=*/true, MatReason::Phi,
                                      /*TargetMerge=*/BB);
        if (!Eligible.lookup(InnerID)) {
          Eligible[NewID] = false;
          return false;
        }
        // Same defensive ExitInfo rewrite as the merge per-VO loop; see the
        // matching comment in mergeFieldStates.
        Value *InnerValue = realIdentityOf(InnerID);
        ExitInfos[i]->FieldStates[PerPredIDs[i]][P.Off] =
            jeandle::FieldValue::materializedRef(InnerValue);
        In = InnerValue;
      } else {
        Eligible[NewID] = false;
        return false;
      }
      InValues.push_back(In);
    }
    // Route through the LoopFieldPhiCache so the per-(BB, NewID, Off) PHI
    // shell is REUSED across loop-fixpoint iterations. Same Value* across
    // iters keeps FieldStates structurally equivalent for convergence and
    // keeps a PHI named by B alive across rollback. For BBs outside any loop
    // the cache is bypassed (getOrCreateLoopFieldPhi falls back to
    // createUnparentedPhi).
    PHINode *NewPhi = getOrCreateLoopFieldPhi(BB, NewID, P.Off, P.PhiType,
                                              OriginalN, "pea.casec.field.phi");
    PhiHome[NewPhi] = BB;
    auto PE = std::make_unique<jeandle::CreatePHIEffect>();
    PE->Block = BB;
    // SeqNo assigned at drain time; see PendingMergePhis comment.
    PE->SeqNo = 0;
    PE->setMutationOwner(NewID);
    PE->PhiInst = NewPhi;
    PE->PHIType = P.PhiType;
    PE->FieldOffset = P.Off;
    unsigned LiveIndex = 0;
    for (unsigned OriginalIndex = 0; OriginalIndex < OriginalN;
         ++OriginalIndex) {
      if (Dead[OriginalIndex]) {
        PE->PHIIncomingValues.push_back(PoisonValue::get(P.PhiType));
        PE->PHIIncomingBlocks.push_back(Phi->getIncomingBlock(OriginalIndex));
        continue;
      }
      assert(LiveIndex < InValues.size() &&
             PerPredOriginalIndices[LiveIndex] == OriginalIndex &&
             "Case-C live input must retain its original PHI index");
      PE->PHIIncomingValues.push_back(InValues[LiveIndex]);
      PE->PHIIncomingBlocks.push_back(Preds[LiveIndex]);
      ++LiveIndex;
    }
    assert(LiveIndex == InValues.size());
    PendingPhiEffects.add(std::move(PE));
    if (P.PhiType->isPointerTy())
      Merged[P.Off] = jeandle::FieldValue::materializedRef(NewPhi);
    else
      Merged[P.Off] = jeandle::FieldValue::scalar(NewPhi);
  }

  // Route this synthetic VO's field-PHI effects to the caller's buffer (the
  // MergeProcessor's MergeEffects for a merge, PendingMergePhis[BB] for an
  // entry/single-pred path). They are assigned SeqNos at drain time.
  Out.addAll(PendingPhiEffects);
  CurrentState.addObject(NewID, jeandle::ObjectState());
  Eligible[NewID] = true;
  // Refresh the merged field state unconditionally: with the phi-keyed
  // cache the same synthetic ID is reused across loop-fixpoint passes with
  // an evolving source set, so a pass whose merge produces no differing
  // entries must still overwrite the previous pass's entries.
  FieldStates[NewID] = std::move(Merged);
  FieldDefinitions[NewID] = std::move(MergedDefinitions);
  if (RefLC != 0) {
    LockCounts[NewID] = RefLC;
    const auto &RefStack = ExitInfos[0]->LiveLockEnters.lookup(PerPredIDs[0]);
    if (!RefStack.empty())
      LiveLockEnters[NewID] = RefStack;
  }
  Aliases.addVirtualAlias(Phi, NewID, /*IsWholeObject=*/true);
  LLVM_DEBUG(dbgs() << "PEA-CASEC-SUCCESS: synthesized VO=" << NewID
                    << " for phi '" << Phi->getName() << "' at merge "
                    << BB->getName() << "\n");
  // Record (or overwrite, when a stale entry's VO went ineligible) the
  // phi-keyed cache entry. On a cache hit the entry already maps this PHI
  // to NewID; assignment is idempotent.
  if (InLoop)
    CaseCVOCache[Phi] = NewID;
  return true;
}

void Analyzer::processInstruction(Instruction *I) {
  HandledDeoptCall = nullptr;
  HandledDeoptOperandNos.clear();

  // Per-instruction dispatch, in three stages:
  //
  //   (1) ALLOCATION STAGE: a jeandle.new_instance / jeandle.new_array site
  //       goes to processAllocation, which virtualizes it (gates documented
  //       there); the site's own deopt bundle is then recorded and its
  //       remaining virtual operands materialized before dispatch returns.
  //   (2) FOLD STAGE: the per-opcode handlers — processStore / processLoad
  //       (access folding against a virtual base), propagatePointerAlias
  //       (alias forwarding through LLVM pointer derivation), processIntrinsic
  //       (known non-escaping LLVM intrinsics), foldICmpEquality (identity
  //       compares), and processJavaOp (arraylength / load_klass / instanceof
  //       / monitor / array_store_check / ... folds). Access folding runs
  //       ahead of the hasVirtualInputs gate and resolves the pointer itself;
  //       the remaining folds run under the gate.
  //   (3) GENERIC ESCAPE STAGE: materializeAllVirtualOperands materializes
  //       every virtual operand the fold stage did not itself account for.
  //
  // CONTRACT: a fold-stage handler may return / early-exit ONLY once every
  // virtual operand has been folded or materialized. A handler that leaves a
  // virtual operand unaccounted for MUST fall through to stage (3) so the
  // generic escape path materializes it.
  //
  // PHINodes are handled in processBlockPhis (which runs before this loop)
  // and have their alias status (Case B) or per-pred materialization (Case A)
  // recorded there. Re-walking them in the generic instruction dispatch would
  // hit the hasVirtualInputs fall-through and incorrectly trigger
  // materializeAllVirtualOperands, dropping a successfully-aliased Case-B PHI
  // back to materialized.
  if (isa<PHINode>(I))
    return;

  // Aliases are analyzer-global so a loop retry can carry the preceding
  // header merge's PHI result into the next traversal. A revisited ordinary
  // instruction nevertheless derives its output from the current block state
  // and must discard its own earlier result before dispatch.
  Aliases.resetAlias(I);

  // Allocation: Jeandle allocation site.
  if (auto *CB = dyn_cast<CallBase>(I)) {
    if (jeandle::pea::isJeandleAllocation(CB)) {
      processAllocation(CB);
      // The allocation's OWN deopt bundle (the frontend attaches
      // create_current_deopt_bundle to every new_instance/new_array, which
      // can deopt on unresolved klass / OOM) is a safepoint like any other:
      // a still-virtual VO referenced by it must be described or
      // materialized. Both helpers are no-ops when the bundle has no virtual
      // references, and every processAllocation early-return path (cache
      // hit, finalizer, length cap, ...) still lands here. The transform
      // side is clone-safe: a whole-pool rewrite on the allocation invoke
      // clones it, and every handle to the original
      // (VirtualObject::AllocationCall, effect Targets) follows the RAUW
      // via WeakTrackingVH.
      recordDeoptBundleMappings(CB);
      materializeAllVirtualOperands(CB);
      return;
    }
  }

  // Store/Load — try them regardless of the hasVirtualInputs gate.
  // processStore/processLoad resolve the pointer through GEPs/casts and
  // early-exit if it doesn't bottom out on a virtual base.
  if (auto *SI = dyn_cast<StoreInst>(I)) {
    // processStore returns true if the POINTER side was a virtual,
    // i.e. it consumed the store. If false, we MUST fall through to the
    // generic hasVirtualInputs path so a VALUE-side virtual reference
    // (e.g. `store ptr %virtAlloc, ptr @G`) escapes correctly instead of
    // silently surviving in IR as a `store poison, ptr @G` after
    // EliminateAllocation RAUWs the virtual to PoisonValue.
    if (processStore(SI))
      return;
    // Fall through.
  } else if (auto *LI = dyn_cast<LoadInst>(I)) {
    processLoad(LI);
    return;
  }

  // TODO(unsafe-inliner): see the access dispatch (processStore/processLoad).
  // atomicrmw/cmpxchg falls through to the generic-escape path below,
  // materializing conservatively.

  // Strict-lock cascade: under strict lock order, a REAL (non-virtualized)
  // monitorenter must first materialize every still-virtual object holding a
  // shallower live lock, so each such object's re-emitted lock lands below
  // this real lock on the lightweight-locking thread lock stack (preserving
  // lexical nesting).
  //
  // Placement: a Jeandle monitorenter carries no deopt frame state
  // referencing its receiver (deopt is deferred), so a non-virtual receiver
  // has NO virtual input and never enters the hasVirtualInputs gate below —
  // the cascade is therefore checked here, outside the gate. A
  // virtual-receiver monitorenter is handled by foldMonitorEnter inside the
  // gate (elision + its own elide-path pre-cascade), so this fires only when
  // the receiver does NOT resolve to a virtual.
  if (StrictLockOrder && MonitorDepth.Valid) {
    if (auto *CB = dyn_cast<CallBase>(I)) {
      if (jeandle::pea::isJeandleMonitorEnter(CB) && CB->arg_size() >= 1) {
        auto RecvID = jeandle::pea::resolveVirtualRef(
            CB->getArgOperand(0), CurrentState, Aliases, DL);
        if (!RecvID)
          materializeVirtualLocksBefore(CB);
      }
    }
  }

  // Other virtual-input consumers (access folding + scalar-replaced inputs).
  if (Aliases.hasVirtualInputs(I)) {
    // Pointer-derivation forwards the virtual alias to the derived pointer so
    // downstream load/store handlers can pick up the base via the alias map.
    // SelectInst is included: when both arms resolve to the same virtual
    // ObjectID, the Select denotes that virtual on every execution path.
    // propagatePointerAlias additionally guards Select on per-arm byte offset
    // (mirroring processBlockPhis' AnyDerived): a Select whose arms carry a
    // non-zero field offset materializes rather than alias-forwarding, since
    // resolveFieldOffset has no Select case and would otherwise lose the
    // offset.
    if (isa<GetElementPtrInst>(I) || isa<BitCastInst>(I) ||
        isa<AddrSpaceCastInst>(I) || isa<FreezeInst>(I) || isa<SelectInst>(I)) {
      propagatePointerAlias(I);
      return;
    }
    // Known non-escaping LLVM intrinsics (assume, lifetime markers,
    // invariant markers, debug intrinsics, ...) are no-ops for PEA. The
    // virtual stays virtual and the call is left alone in IR (some are
    // DCE'd downstream; others are harmless). launder/strip.invariant.group
    // forward the argument's virtual alias. Must run BEFORE the JavaOp fold +
    // generic-escape fall-through.
    if (auto *II = dyn_cast<IntrinsicInst>(I)) {
      if (processIntrinsic(II)) {
        // A handled intrinsic's ordinary arguments and informational bundles
        // are non-escaping, but a deopt bundle is executable frame state.
        // Describe its virtual roots, then materialize only roots that could
        // not be described, before taking the intrinsic's early return.
        recordDeoptBundleMappings(II);
        materializeUnhandledDeoptBundleOperands(II);
        return;
      }
      // default: fall through to the ICmp / JavaOp / generic-escape path.
    }
    // TODO(deferred-virtualizers): deferred virtualization handlers — NOT WIRED
    // yet:
    //   - TODO: processArrayCopy / processMemSet — llvm.memcpy/memmove
    //     (System.arraycopy) and llvm.memset (Arrays.fill). The only
    //     llvm.memset producer today is jeandle.new_instance's lower-phase=1
    //     template, inlined AFTER PEA, so neither shape reaches PEA yet.
    //   - TODO: llvm.reachability_fence — upstream LLVM this fork tracks
    //     does not define Intrinsic::reachability_fence, and the frontend
    //     emits no analogue.
    //   - TODO: ObjectClone / FinalFieldBarrier / EnsureVirtualized — no
    //     jeandle.clone / final_field_barrier / ensure_virtualized JavaOp
    //     exists in the frontend inventory.
    //   - get_class: IMPLEMENTED (foldGetClass). The frontend emits
    //     jeandle.get_class for vmIntrinsic _getClass
    //     (jeandleIntrinsicLowering.cpp). A virtual receiver of known klass
    //     folds to a GC-safe load of its java.lang.Class mirror: the
    //     GetJavaMirror VMCallback maps the klass to a mirror oop id, and the
    //     transform builds the oop-handle load (createConstOopLoad) recorded
    //     via ReplaceCallEffect::OopHandleId. When the callback is unavailable
    //     (offline tests without a callback log) or returns -1, foldGetClass
    //     bails and this fall-through materializes (sound, conservative).
    //
    // Current frontend JavaOp inventory (regenerate with:
    //   grep -rhoE 'jeandle\.[a-z0-9_]+' \
    //     jeandle-jdk/src/hotspot/share/jeandle/ | sort -u
    // and keep this list in sync). The grep also matches symbols that are NOT
    // user-facing JavaOps — the @jeandle.personality global, and internal
    // helper functions invoked only inside another JavaOp's definition (e.g.
    // g1_pre_barrier / g1_post_barrier / g1_satb_enqueue, called from
    // pre_barrier / post_barrier and never emitted as standalone calls) —
    // which are excluded below: array_store_check, arraylength,
    // card_table_barrier, check_if_value_based, check_inflated,
    // check_instanceof, check_klass_subtype, check_klass_subtype_slow_path,
    // checkcast, clear_oop_in_lock_stack_top, current_thread,
    // decrement_lock_count, g1_pre_barrier_loaded, get_class,
    // get_stack_pointer, idiv, increment_lock_count, instanceof, irem, ldiv,
    // load_klass, lrem, monitorenter_with_lightweight_lock,
    // monitorenter_with_monitor_lock, monitorenter_with_thin_lock,
    // monitorexit_with_lightweight_lock, monitorexit_with_monitor_lock,
    // monitorexit_with_thin_lock, new_instance, new_array, post_barrier,
    // pre_barrier, reference_get, reference_refers_to,
    // register_finalizer_if_needed, safepoint_poll, try_acquire_monitor_lock,
    // try_release_monitor_lock. (NOT all listed here get a dedicated fold in
    // processJavaOp — see the isJeandle* predicates in
    // PartialEscapeUtils.{h,cpp} for which the analyzer actually recognizes.)
    //
    // TODO(compressed-oop): decode_heap_oop, decode_klass, encode_heap_oop,
    // and encode_klass are frontend JavaOps deferred until CompressedOops
    // support lands; explicitly excluded from PEA scope today.
    //
    // When the frontend grows a new JavaOp, wire its fold in processJavaOp
    // and add the isJeandle* predicate in PartialEscapeUtils.{h,cpp}.
    //
    // Equality compare against a virtual pointer folds (virtuals are never
    // null; identity comparison). Non-equality ICmp on virtual heap pointers
    // (slt/sgt/...) is UB on GC pointers; fall through to conservative
    // materialization.
    if (auto *ICmp = dyn_cast<ICmpInst>(I)) {
      if (foldICmpEquality(ICmp))
        return;
    }
    // Recognise JavaOps that read/inspect a virtual receiver and try to
    // constant-fold them. processJavaOp returns true if the JavaOp was
    // handled (whether by folding to a constant or by being a known-safe
    // non-escaping shape that needs no transform).
    if (auto *CB = dyn_cast<CallBase>(I)) {
      if (processJavaOp(CB)) {
        // The call was folded / is a known-safe shape. It may still SURVIVE
        // with a deopt bundle (the fold effect can be dropped at commit when
        // the VO becomes ineligible), so its bundle operands must be
        // recorded: VOs describable here stay virtual; the rest are handled
        // by the generic escape path when their effects survive. When the
        // fold survives, the rewrite no-ops at apply (the bundle died with
        // the call). No foldable JavaOp carries a deopt bundle, so this path
        // is latent.
        recordDeoptBundleMappings(CB);
        return;
      }
      // Order: materialize the call's REAL virtual inputs BEFORE recording
      // the virtual mappings for its deopt bundle. A VO that is both a real
      // argument AND a deopt-bundle operand of this call must be MATERIALIZED
      // here — the bundle slot then keeps the live OrigAlloc and a
      // during-call deopt sees ONE object identity (caller and callee share
      // the real object). VOs that only REFERENCE an arg-VO from a field
      // flip to MaterializedRef via updateOtherStatesForMaterialized and
      // stay describable as live-oop fields.
      materializeVirtualCallArgs(CB);
      // Record VO descriptors for any still-virtual OrigAlloc referenced in
      // CB's "deopt" bundle. (recordDeoptBundleMappings checks hasDeoptBundle
      // and populates DeoptBundleHandled for THIS call, consumed by
      // materializeAllVirtualOperands below; the transform's apply no-ops
      // if the call/bundle was later folded away, so scanning handled calls
      // is safe.)
      recordDeoptBundleMappings(CB);
    }
    // Any other consumer of a virtual operand: materialize every virtual
    // operand at I (unconditional, per operand). Deopt-bundle operands whose
    // ObjectID is in DeoptBundleHandled are skipped
    // (recordDeoptBundleMappings described them).
    materializeAllVirtualOperands(I);
    return;
  }

  // A safepoint may contain only a durable pool left by an earlier PEA round.
  // It still needs a whole-pool cleanup/idempotence plan even when this round
  // sees no virtual LLVM operand.
  if (auto *CB = dyn_cast<CallBase>(I))
    recordDeoptBundleMappings(CB);
}

// Allocation virtualization. Virtualize a jeandle.new_instance /
// jeandle.new_array site: build the VirtualObject, install a virtual
// ObjectState (a presence marker; per-field values live in FieldStates), add
// the virtual alias (the allocation result denotes the VO itself), and record
// the EliminateAllocation effect the transform's cfg-kill phase later applies
// or drops by final classification. Refusal gates, in order: unsafe cyclic
// SCC blocks, the monotonic suppression set, StopNewInLoopNest mode,
// un-extractable klass/size/length operands, the array-length cap (default
// 128), and the VM-callback identity gates (HasFinalizer / CanVirtualize).
// AllocSiteToVO pins one ObjectID per site so loop-fixpoint re-processing
// converges on stable IDs.
void Analyzer::processAllocation(CallBase *CB) {
  // LoopInfo models reducible natural loops, but a reachable cyclic SCC may
  // have multiple entries and no single Loop covering all of its blocks.
  // Such a region is processed only once by the outer RPO walk, so an
  // allocation discovered after an earlier SCC block cannot be tracked
  // soundly. Keep it real before assigning an ObjectID or recording effects.
  if (UnsafeCyclicBlocks.contains(CB->getParent()))
    return;

  // A structural/materialization failure or failed final obligation retries
  // analysis from untouched IR with every offending original allocation site
  // in this monotonic suppression set. Keeping the allocation real is the
  // conservative fixpoint: all original aliases, uses, and stores are rebuilt
  // consistently, and the same site cannot trigger another
  // virtualization-dependent failure.
  if (SuppressedVirtualizations.count(CB))
    return;

  // In StopNewInLoopNest mode (transiently set by processLoop at a
  // top-level nest whose maximum depth exceeds JeandlePEALoopCutoff),
  // refuse to register NEW virtual allocations inside the nest, but leave
  // every other state intact — already-virtual objects (registered in a
  // shallower enclosing scope, or before the nest entry) continue to be
  // tracked and folded as usual.
  //
  // TODO(ensure-virtualized): GRAAL DIVERGENCE — the refusal below is
  // unconditional, but Graal's processVirtualizable
  // (Graal PartialEscapeClosure) exempts allocations whose usages
  // contain an EnsureVirtualizedNode (the mayEnsureVirtualized scan): such
  // an allocation is still virtualised PAST EscapeAnalysisLoopCutoff
  // (default 20). The marker is produced only by GraalDirectives
  // .ensureVirtualized / ensureVirtualizedHere, lowered by the graph
  // builder to an EnsureVirtualizedNode (Graal EnsureVirtualizedNode /
  // StandardGraphBuilderPlugins). Jeandle's frontend has no
  // ensure_virtualized JavaOp / intrinsic, so mayEnsureVirtualized would be
  // uniformly false here — there is currently nothing to override.
  //
  // The override is one leg of a three-part Graal design that must be
  // wired up together:
  //  (1) Override at this site — needs an IR marker the analyser recognises
  //      plus an EnsureVirtualized bit on ObjectState (serialised through
  //      clone / takeLoopSnapshot / restoreLoopSnapshot).
  //  (2) Materialisation guard — Graal's ensureMaterialized
  //      (Graal PartialEscapeClosure) throws RetryableBailoutException
  //      (a non-permanent bailout: retry the whole compilation without PEA)
  //      when an ensure-virtualised object must be materialised inside a
  //      deep nest, which is what keeps the override from going exponential
  //      in nest depth. Jeandle is -fno-exceptions with no per-pass
  //      bailout, so this leg is deopt-adjacent and deferred — see the
  //      matching note in ensureMaterialized below.
  //  (3) Flag bookkeeping — AND-reduce the bit across merge predecessors
  //      with setEnsureVirtualized(false) where not all preds agree
  //      (Graal PartialEscapeClosure) and
  //      propagate it transitively in stripKilledLoopLocations.
  //      Jeandle's ObjectState has no such bit, so the per-pred materialisation
  //      sites that route through materializeAtPredFromExitInfo currently do no
  //      downgrade either — tagged TODO(ensure-virtualized) at their entry
  //      points (materializePredsAndMerge, which the AllMaterialized-divergence
  //      arm of mergeObjectState routes through; and synthesizeCaseC).
  //
  // Soundness: the unconditional return below is CONSERVATIVE — Jeandle
  // merely virtualises less than Graal in deep nests; it never miscompiles.
  // Were an ensure-virtualised marker to appear today, the object would
  // simply stay in IR and be materialised at its escape point, preserving
  // correctness while violating the (advisory) directive.
  if (CurrentMode == Mode::StopNewInLoopNest)
    return;

  // In MATERIALIZE_ALL mode the analyzer registers the VO normally
  // (so intra-block processLoad/processStore folds against the new
  // FieldStates), then defers a Materialize effect to end-of-processBlock so
  // replay occurs at the block's terminator IP — by which time all stores have
  // updated FieldStates. OrigAlloc remains at its source site. Deferring the
  // effect to block end preserves intra-block folds and makes every replay
  // value available at its insertion point.
  const bool VirtualiseThenMaterialise = (CurrentMode == Mode::MaterializeAll);

  // Stable VO-per-allocation-site cache. Re-processing the same alloc
  // inside a loop fixpoint iteration must produce the same ObjectID so the
  // per-block exit snapshots can be compared for convergence. The cache is
  // monotonic (entries are never removed), and ineligibility carries over
  // across rollback boundaries.
  if (auto It = AllocSiteToVO.find(CB); It != AllocSiteToVO.end()) {
    jeandle::ObjectID ID = It->second;
    if (!Eligible.lookup(ID))
      return; // poisoned in a prior iteration — leave the original alloc.
    // Re-register the alias and the virtual ObjectState in CurrentState.
    // Aliases.addVirtualAlias asserts !already-aliased, so call only when
    // the cache restore has wiped the entry (the common case under
    // restoreLoopSnapshot, which restores Aliases to its pre-loop state).
    if (!Aliases.getVirtualAlias(CB))
      Aliases.addVirtualAlias(CB, ID, /*IsWholeObject=*/true);
    if (!CurrentState.hasObjectState(ID))
      CurrentState.addObject(ID, jeandle::ObjectState());
    // Re-emit the EliminateAllocation effect. The pre-iter snapshot has
    // wiped BlockEffects[CB->getParent()] of this iteration's prior copy,
    // and addBlockEffect doesn't dedup, so this is exactly the right place.
    auto E = std::make_unique<jeandle::EliminateAllocationEffect>();
    E->Block = CB->getParent();
    E->Target = CB;
    E->SeqNo = Result.nextSeqNo();
    E->setMutationOwner(ID);
    Result.addBlockEffect(std::move(E));
    // Also re-enqueue the per-block materialise on the cache-hit
    // path. For an InvokeInst alloc, the alloc IS the terminator of its
    // block, so we cannot drain at end-of-current-block (the alloc only
    // gets registered AFTER our drain hook would fire). Defer to the
    // NORMAL-dest block: that's where downstream processLoad/processStore
    // fold the VO's FieldStates, and end-of-that-block is the correct
    // dominance-safe materialise IP.
    if (VirtualiseThenMaterialise) {
      BasicBlock *MatBB = CB->getParent();
      if (auto *II = dyn_cast<InvokeInst>(CB))
        MatBB = II->getNormalDest();
      PendingMaterializeAllVOs[MatBB].push_back(ID);
    }
    return;
  }

  // Loop-body allocations are permitted as virtualization candidates. The
  // availability gate in ensureMaterialized checks every replay value at the
  // actual escape/edge replay point. A field value defined after OrigAlloc is
  // therefore valid when it dominates that point; otherwise the object becomes
  // ineligible and the original IR survives.
  // materializePreheaderVirtualsForUnvisitedLoops independently drains a
  // preheader only when processLoop never visited that loop. Normal loops carry
  // pre-loop objects through the B/B' fixpoint; overflow/non-convergence
  // recovery drains them before the MaterializeAll retry.

  uintptr_t Klass = jeandle::pea::extractAllocationKlass(CB);
  if (Klass == 0)
    return;

  const bool IsInstance = jeandle::pea::isJeandleNewInstance(CB);
  const bool IsArray = jeandle::pea::isJeandleNewArray(CB);
  assert((IsInstance ^ IsArray) &&
         "allocation must be either instance or array");
  (void)IsArray;

  // The third operand of jeandle.new_instance is not an allocation hint. It
  // selects the runtime slow path, which performs initialization and
  // instantiation checks with observable exception/side-effect semantics.
  // PEA does not model that path, so only the exact fast-path form is
  // virtualizable. In particular, a runtime-unknown value must not be
  // treated as false merely because the fast path is the common case.
  if (IsInstance) {
    if (CB->arg_size() != 3)
      return;
    auto *InitialSlowTest = dyn_cast<ConstantInt>(CB->getArgOperand(2));
    if (!InitialSlowTest || !InitialSlowTest->getType()->isIntegerTy(1) ||
        !InitialSlowTest->isZero())
      return;
  }

  // Refuse to virtualize identity-sensitive allocations.
  // HasFinalizer: classes that override finalize() require HotSpot's
  // RegisterFinalizer hook to fire at the original allocation site;
  // eliding the alloc would skip finalizer registration and break
  // user-visible semantics.
  // CanVirtualize: Reference / Thread (and subtypes) have lifecycle
  // tracked by global runtime state (pending-reference list, thread
  // list); virtualizing them would silently elide that tracking.
  // Both checks fire only on instance allocations (arrays cannot have
  // finalizers, and HotSpot's finalizer / Reference / Thread machinery
  // is keyed on InstanceKlass identity). When no VM callback log is
  // registered (offline lit tests) both callback pointers are nullptr and
  // the default is to virtualize.
  if (IsInstance) {
    if (const jeandle::VMCallbacks *VMCB = jeandle::getVMCallbacks()) {
      if (VMCB->HasFinalizer && VMCB->HasFinalizer(Klass))
        return;
      if (VMCB->CanVirtualize && !VMCB->CanVirtualize(Klass))
        return;
    }
  }

  std::unique_ptr<jeandle::VirtualObject> VO;

  if (IsInstance) {
    auto Size = jeandle::pea::extractInstanceSize(CB);
    if (!Size)
      return;
    VO = std::make_unique<jeandle::VirtualObject>(
        jeandle::InvalidObjectID, jeandle::VirtualObject::Instance, CB);
    VO->Klass = Klass;
    VO->SizeInBytes = *Size;
  } else {
    auto Length = jeandle::pea::extractArrayLength(CB);
    if (!Length)
      return;
    if (*Length > MaximumEscapeAnalysisArrayLength)
      return;
    VO = std::make_unique<jeandle::VirtualObject>(
        jeandle::InvalidObjectID, jeandle::VirtualObject::Array, CB);
    VO->Klass = Klass;
    VO->ArrayLength = *Length;
    // Populate per-element metadata so matchArrayElementGEP can match
    // typed-GEP / symbolic-byte-offset element accesses. If the VMCallback
    // is unregistered or cannot identify the element kind, leave
    // ArrayElementType nullptr — matchArrayElementGEP will refuse to fire
    // and only constant-byte-offset element accesses (handled directly by
    // resolveFieldOffset) will be eligible. ArrayBaseOffset is always set
    // (per-kind when known, else the VM's Object-kind default) so the
    // resolveAccess header guard never degrades to `< 0`.
    jeandle::JBasicType Kind = jeandle::elementTypeForArrayKlass(Klass);
    if (Kind != jeandle::JBasicType::Count) {
      VO->ArrayBaseOffset =
          static_cast<uint32_t>(VMConsts.arrayBaseOffsetFor(Kind));
      if (Type *ElemTy =
              jeandle::pea::llvmElementTypeFor(Kind, F.getContext())) {
        VO->ArrayElementType = ElemTy;
        VO->ArrayIndexScale =
            static_cast<uint32_t>(VMConsts.elementSizeFor(Kind));
      }
    } else {
      // Unknown element kind: we cannot pin the per-kind element type, but
      // the array header size is uniform across element kinds (mark + klass
      // + length, padded), so fall back to the Object-kind base offset (16
      // by default, or the module-overridden Object value). This keeps the
      // resolveAccess header guard `*Offset < ArrayBaseOffset` rejecting
      // raw header GEPs (offset < ArrayBaseOffset) instead of degrading to
      // `< 0` (which would let a raw mark/klass GEP virtualize as a Java
      // field) while still accepting element GEPs (offset >=
      // ArrayBaseOffset; see
      // llvm/test/Jeandle/partial-escape/397_phi_case_c_array_merge.ll).
      // ArrayElementType / ArrayIndexScale stay null / 0 so the typed-GEP
      // fast path stays inert (correct for unknown-kind arrays).
      VO->ArrayBaseOffset = static_cast<uint32_t>(
          VMConsts.arrayBaseOffsetFor(jeandle::JBasicType::Object));
    }
  }

  // Create the virtual object: assign the ObjectID, install a virtual
  // ObjectState, register the virtual alias, mark the original allocation
  // for elimination, and account the delta. The deferred-transform design
  // (no IR mutation during analysis) shapes the mechanics:
  //   - the id is cached per allocation site (AllocSiteToVO) so loop-fixpoint
  //     re-processing yields a STABLE ObjectID for the convergence comparison;
  //   - instead of erasing the allocation now, an EliminateAllocation effect
  //     is emitted, applied by the transform later;
  //   - the per-field FieldValue tracking lives in the analyzer-side
  //     FieldStates map (the on-VO ObjectState carries no field state) — see
  //     the class comment.
  jeandle::ObjectID ID = Result.createVirtualObject(std::move(VO));
  AllocSiteToVO[CB] = ID; // Jeandle: stable id per site (loop fixpoint).
  Aliases.addVirtualAlias(CB, ID, /*IsWholeObject=*/true);
  // Register a Virtual ObjectState — a presence marker carrying only Kind ==
  // Virtual. resolveVirtualRef only needs the slot present; the per-field
  // FieldValue tracking lives in FieldStates (see class comment).
  CurrentState.addObject(ID, jeandle::ObjectState());
  Eligible[ID] = true;

  // Record the EliminateAllocation effect; the transform's cfg-kill phase
  // erases the alloc for NeverEscapes VOs and suppresses the effect for
  // PartiallyEscapes VOs (keeping OrigAlloc alive as the materialized value).
  auto E = std::make_unique<jeandle::EliminateAllocationEffect>();
  E->Block = CB->getParent();
  E->Target = CB;
  E->SeqNo = Result.nextSeqNo();
  E->setMutationOwner(ID);
  Result.addBlockEffect(std::move(E));

  ++Result.VirtualizationDelta;
  --Result.AllocationDelta;
  ++AttemptStats.Virtualized;

  // Enqueue end-of-block materialise under VirtualiseThenMaterialise.
  // For an InvokeInst alloc the alloc IS the block terminator; drain in
  // the normal destination instead so subsequent field accesses in that
  // block fold first.
  if (VirtualiseThenMaterialise) {
    BasicBlock *MatBB = CB->getParent();
    if (auto *II = dyn_cast<InvokeInst>(CB))
      MatBB = II->getNormalDest();
    PendingMaterializeAllVOs[MatBB].push_back(ID);
  }
}

// Resolve an access pointer whose base is the virtual object BaseID to a
// constant byte offset within the object. Recognizes the typed-element GEP
// fast path for arrays with element metadata, then falls back to the general
// constant-offset resolver. Returns nullopt when the access cannot be
// tracked — a symbolic or out-of-bounds array index, a non-constant GEP
// offset, or a header (mark/klass word) offset, which must never be
// virtualized into a field slot; callers materialize on nullopt.
std::optional<int64_t> Analyzer::resolveAccess(Value *Ptr,
                                               jeandle::ObjectID BaseID) {
  jeandle::VirtualObject &VObj = *Result.VirtualObjects[BaseID];

  // Array-element GEP fast path: for array VOs with populated element
  // metadata, recognise the typed-element GEP the abstract interpreter emits
  // for indexed accesses. matchArrayElementGEP returns {idx, etype} on a
  // recognised shape; idx is a ConstantInt for constant indices (use the
  // canonical byte offset) and any other Value for symbolic indices (force
  // materialization, matching the "constant index only" policy).
  if (VObj.isArray() && VObj.ArrayElementType) {
    if (auto *G = dyn_cast<GetElementPtrInst>(Ptr)) {
      if (auto Match = VObj.matchArrayElementGEP(G, DL)) {
        if (auto *CI = dyn_cast<ConstantInt>(Match->Index)) {
          std::optional<int64_t> Cidx = CI->getValue().trySExtValue();
          if (!Cidx || *Cidx < 0 ||
              static_cast<uint64_t>(*Cidx) >= VObj.ArrayLength)
            return std::nullopt; // out of bounds
          std::optional<int64_t> ElementOffset =
              jeandle::pea::checkedArrayElementOffset(
                  VObj.ArrayBaseOffset, *Cidx, VObj.ArrayIndexScale);
          if (!ElementOffset ||
              !jeandle::pea::isUsableFieldOffset(*ElementOffset))
            return std::nullopt;
          return ElementOffset;
        }
        return std::nullopt; // symbolic index
      }
    }
  }

  // General constant-offset resolver. A non-constant GEP offset yields
  // nullopt (caller materializes).
  std::optional<int64_t> Offset = jeandle::pea::resolveFieldOffset(Ptr, DL);
  if (!Offset)
    return std::nullopt;

  // Header-offset guard: mark/klass words are VM metadata, not Java fields,
  // and must not be virtualized into a field slot. Instances are guarded by
  // instanceBaseOffset; arrays are mirrored by ArrayBaseOffset (a raw GEP
  // into the array header, e.g. an offset-0 store to the mark word, would
  // otherwise replay as a Java-field write on materialization). The frontend
  // keeps every header access inside a lower-phase >= 1 JavaOp that PEA
  // folds by name (load_klass, arraylength, the monitor ops, ...), so the
  // instance side of this guard is unreachable for frontend-emitted IR, and
  // the materializing callers run checkRawHeaderAccess
  // (JeandlePEAVerifyHeaderAccess) to turn an instance-side violation into a
  // diagnosable failure instead of a silent performance regression. The array
  // side stays reachable by design: with no element metadata available, a
  // constant negative array index (the typed-element GEP shape) skips the
  // array-element fast path and resolves here to a sub-base byte offset,
  // which is a legitimate out-of-bounds case, not a header access —
  // checkRawHeaderAccess skips arrays for that reason.
  if (VObj.isInstance()) {
    if (*Offset < VMConsts.instanceBaseOffset())
      return std::nullopt;
  } else if (VObj.isArray()) {
    // Reject offsets outside the array's element byte-range [ArrayBaseOffset,
    // ArrayBaseOffset + ArrayLength*scale). The lower bound guards the header;
    // the upper bound rejects an out-of-bounds tail byte-GEP (e.g. `gep i8
    // %arr, base + N*scale` with N >= ArrayLength) that matchArrayElementGEP
    // already declined — without it the generic resolver would model the
    // past-the-end offset as a phantom field that is never replayed (the emit
    // loop walks only 0..ArrayLength-1), silently dropping the store.
    //
    // The upper bound is enforceable only when the element scale is known
    // (ArrayIndexScale > 0, i.e. ArrayElementType was supplied via the VM
    // callback log). With an unknown scale, no layout-derived upper bound can
    // be proved here; constant offsets after the header remain raw field slots.
    // Those slots are replayed individually if the allocation survives. A
    // NeverEscapes allocation needs no replay because both it and its
    // unobservable stores are eliminated.
    int64_t BaseOff = static_cast<int64_t>(VObj.ArrayBaseOffset);
    if (*Offset < BaseOff)
      return std::nullopt;
    if (VObj.ArrayIndexScale > 0) {
      std::optional<int64_t> EndOff = jeandle::pea::checkedArrayElementOffset(
          BaseOff, VObj.ArrayLength, VObj.ArrayIndexScale);
      if (!EndOff)
        return std::nullopt;
      if (*Offset >= *EndOff)
        return std::nullopt; // out-of-bounds tail byte-GEP — bail
    }
  }

  return Offset;
}

void Analyzer::checkRawHeaderAccess(const Instruction *I, Value *Ptr,
                                    jeandle::ObjectID BaseID) {
  if (JeandlePEAVerifyHeaderAccess == HeaderAccessCheck::Off)
    return;
  jeandle::VirtualObject &VObj = *Result.VirtualObjects[BaseID];
  if (!VObj.isInstance())
    return;
  std::optional<int64_t> Offset = jeandle::pea::resolveFieldOffset(Ptr, DL);
  if (!Offset || *Offset >= VMConsts.instanceBaseOffset())
    return;
  std::string Msg;
  llvm::raw_string_ostream OS(Msg);
  OS << "PEA: raw object-header memory access (constant byte offset " << *Offset
     << " < instanceOopDesc.base_offset_in_bytes "
     << VMConsts.instanceBaseOffset() << ") in function '"
     << I->getFunction()->getName() << "': " << *I;
  llvm::StringRef MsgRef = OS.str();
  if (JeandlePEAVerifyHeaderAccess == HeaderAccessCheck::Fatal)
    llvm::report_fatal_error(MsgRef);
  else
    llvm::errs() << "PEA WARNING: " << MsgRef.drop_front(5) << "\n";
}

// Fold a store whose pointer operand bottoms out on a virtual base. On a
// tracked store the value is recorded in FieldStates (keyed by raw byte
// offset, with the reaching definition in FieldDefinitions) and an
// EliminateStoreEffect is emitted; a stored value denoting a whole inner
// virtual object is recorded as a VirtualRef for the materializer to replay
// as a nested reference. Returns true iff the pointer side resolved to a
// virtual (the store was consumed); on false the caller must run the generic
// escape path so a virtual VALUE operand still escapes. When the store
// cannot be virtualized — volatile access, unresolvable offset, type/size
// conflict, or a virtual-but-derived stored value — the base and a virtual
// stored value are materialized AT the store and the real store survives,
// still reported as consumed. After a function-wide bail (ineligible base)
// only the stored value is materialized: the original allocation and stores
// stay real and no new EliminateStoreEffect may be recorded.
bool Analyzer::processStore(StoreInst *SI) {
  Value *Ptr = SI->getPointerOperand();
  Value *Val = SI->getValueOperand();

  // Normalize the stored value through the scalar-alias chain before any
  // resolution / recording. A value folded by processLoad / foldICmpEquality /
  // emitReplaceCall is RAUW'd and ERASED by its ReplaceLoad/ReplaceCall effect
  // in phase 1, which runs BEFORE the Materialize / RewriteDeoptPool effects
  // that read the FieldStates snapshot — recording the folded instruction
  // itself would leave a dangling pointer in the snapshot. The chain
  // terminates at a value that is never erased (a constant, an argument, an
  // OrigAlloc, or a real SSA def that dominates this store): the fold that
  // produced the alias always precedes the store in RPO, so the alias is
  // registered by the time we see the store. A value carrying a VIRTUAL alias
  // never carries a scalar alias, so this does not change the
  // resolveVirtualRef outcome below.
  while (Value *A = Aliases.getScalarAlias(Val))
    Val = A;

  // Java volatile fields reach this layer as atomic accesses with the
  // appropriate ordering, not as LLVM `volatile`. LLVM volatile has separate
  // observable/MMIO semantics and its operation count must be preserved; it
  // is handled conservatively below.
  auto BaseID = jeandle::pea::resolveVirtualRef(Ptr, CurrentState, Aliases, DL);
  if (!BaseID)
    return false;

  jeandle::VirtualObject &VObj = *Result.VirtualObjects[*BaseID];

  // The store could not be virtualized. Materialize the base AT the store:
  // tracked field stores are replayed onto OrigAlloc right before SI, and
  // OrigAlloc is kept (PartiallyEscapes), so the pre-computed derived/
  // symbolic store address stays valid. The stored value, if itself virtual,
  // is materialized at the store too, so the surviving real store writes a
  // live pointer. The store itself stays as a real store (no
  // EliminateStoreEffect is emitted); returning true keeps processInstruction
  // from re-running the gate on it.
  //
  // The stored value Val could be virtual-derived yet have resolveVirtualRef
  // fail STRUCTURALLY (depth cap, opaque non-round-trip inttoptr), leaving
  // the surviving real store with an unaccounted virtual operand that could
  // classify a VO NeverEscapes -> poison. Eager handling closes that hole:
  // Val's VO is materialized BEFORE the store. AliasMap::addVirtualAlias
  // marks every user of a virtual-aliased value HasVirtualInputs;
  // propagatePointerAlias (GEP/cast/freeze/select) materializes-on-failure
  // and alias-registers each derivation level (so resolveVirtualRef shortcuts
  // — depth cap unreachable for these); and the generic escape path
  // materializes any other instruction with virtual inputs, including
  // ptrtoint (so a VO whose address is converted to an integer, then tagged
  // via add/inttoptr, is materialized at the ptrtoint). By the time Val
  // reaches this store its VO is either alias-registered (resolveVirtualRef
  // finds it) or already materialized upstream. The debug assert below
  // verifies the invariant so a future change that re-opens the hole fails
  // loudly instead of silently poisoning. See lit tests
  // resolve_cap_01_deep_freeze_chain_call_arg.ll and
  // resolve_cap_02_opaque_inttoptr_escape.ll under
  // llvm/test/Jeandle/partial-escape/.
  auto materializeStoredValue = [&] {
    if (auto RefID =
            jeandle::pea::resolveVirtualRef(Val, CurrentState, Aliases, DL)) {
      materializeAt(*RefID, SI, MatReason::Unhandled);
    } else {
      assert(!debugReferencesLiveVirtualObject(Val) &&
             "unresolved store value references a still-virtual VO: eager "
             "materialization regressed (resolve-cap-blind-spot)");
    }
  };
  auto materializeOperandsAtStore = [&] {
    materializeAt(*BaseID, SI, MatReason::Unhandled);
    materializeStoredValue();
  };

  // A function-wide bail keeps the original allocation and every subsequent
  // store real. The virtual marker may remain solely to carry reaching
  // definitions from stores eliminated before the bail; never add a new
  // EliminateStoreEffect after eligibility has been lost.
  if (!Eligible.lookup(*BaseID)) {
    materializeStoredValue();
    return true;
  }

  if (SI->isVolatile()) {
    materializeOperandsAtStore();
    return true;
  }

  // Shared offset resolution (array-element GEP fast path + constant-offset
  // resolver + header guard). See resolveAccess. Unresolved offset (symbolic
  // array index, non-constant GEP, header offset) -> bail.
  std::optional<int64_t> Offset = resolveAccess(Ptr, *BaseID);
  if (!Offset) {
    checkRawHeaderAccess(SI, Ptr, *BaseID);
    materializeOperandsAtStore();
    return true;
  }

  // TODO(unsafe-inliner): see the access dispatch (processStore/processLoad).
  // Unsafe.put{Int,Long,Short}-into-byte-array decomposition.

  // Type-overlap validation via VirtualObject::getOrCreateFieldIndex. We don't
  // actually use the returned index (FieldStates is keyed by raw offset), but
  // -1 means an overlap/size conflict, or an unknown-size value type such as a
  // vector/struct — bail either way.
  if (VObj.getOrCreateFieldIndex(*Offset, Val->getType(), DL) < 0) {
    materializeOperandsAtStore();
    return true;
  }

  // Compute the FieldValue for the stored Value.
  auto StoredIdentity = jeandle::pea::resolveVirtualIdentity(
      Val, CurrentState, Aliases, DL,
      jeandle::pea::VirtualIdentityMode::WholeObject);
  if (StoredIdentity.isDefined()) {
    jeandle::ObjectID RefID = StoredIdentity.getObjectID();
    // Whole-object resolution rejects derived stored values
    // (identity-equal != address-equal).
    // Recording a VirtualRef for a derived stored value (e.g.
    // `store ptr gep(%inner, 8), ptr gep(%outer, 16)`) would silently drop
    // the +8: a later load of the field would fold to the inner's base, and
    // materialization would replay the inner base pointer into the field.
    // Only a value denoting the WHOLE inner object (constant byte offset 0
    // on every path — checked recursively through Select arms and PHI
    // incomings) may be recorded as a VirtualRef; anything else leaves the
    // store in place and materializes both objects at the store. (A
    // successful getOrCreateFieldIndex above may have inserted a FieldDesc
    // before this point — inert, because the object is materialized
    // immediately and never virtualized again: replay is FieldStates-keyed,
    // not FieldDesc-keyed.)
    // Nested virtual reference. Recursive materialization handles this at
    // materialize time by first materializing the inner object then storing
    // its materialized pointer into the outer's field. We record the nested
    // reference here and let materializeAt rewrite it later.
    FieldStates[*BaseID][*Offset] =
        jeandle::FieldValue::virtualRef(RefID, Val->getType());
    FieldDefinitionSet &Defs = FieldDefinitions[*BaseID][*Offset];
    Defs.clear();
    Defs.insert(SI);
    VirtualRefStoreTargets[SI] = RefID;

    auto E = std::make_unique<jeandle::EliminateStoreEffect>();
    E->Block = SI->getParent();
    E->Target = SI;
    E->SeqNo = Result.nextSeqNo();
    E->setMutationOwner(*BaseID);
    Result.addBlockEffect(std::move(E));
    return true;
  }
  // A virtual-derived value that is not a whole-object identity cannot be
  // represented as VirtualRef without losing its offset. Keep the real store
  // and materialize both the stored object's base and the destination.
  if (jeandle::pea::resolveVirtualRef(Val, CurrentState, Aliases, DL)) {
    materializeOperandsAtStore();
    return true;
  }
  FieldStates[*BaseID][*Offset] = jeandle::FieldValue::scalar(Val);
  FieldDefinitionSet &Defs = FieldDefinitions[*BaseID][*Offset];
  Defs.clear();
  Defs.insert(SI);
  VirtualRefStoreTargets.erase(SI);

  auto E = std::make_unique<jeandle::EliminateStoreEffect>();
  E->Block = SI->getParent();
  E->Target = SI;
  E->SeqNo = Result.nextSeqNo();
  E->setMutationOwner(*BaseID);
  Result.addBlockEffect(std::move(E));
  return true;
}

// Fold a load whose pointer operand bottoms out on a virtual base. Paths:
//   - Ineligible base (function-wide bail): the load stays real; every
//     reaching eliminated definition whose tracked byte range overlaps the
//     access is observed so commit keeps it alive.
//   - Volatile load: an observable access (and possibly MMIO), not Java
//     volatile; materialize the base immediately before it and keep the load.
//   - Array-length header load (i32 at ArrayLengthOffset): folds to the
//     known ArrayLength constant — sound even if the array later
//     materializes, since the real array's header length matches.
//   - Otherwise resolveAccess resolves the byte offset; an unresolvable
//     offset (symbolic index, non-constant GEP, header) materializes the
//     base at the load and keeps the real load.
//   - Slot analysis: the load must fall inside one tracked slot. A
//     straddling load (overlaps without containment), an unsized or
//     oversized load, and a sub-slot read of a written field all
//     materialize the base at the load.
//   - A never-written field folds to its Java default value; this fold runs
//     before the sub-slot bail, so a partial read of a never-written wider
//     slot still folds to the default.
//   - A Scalar entry folds through coerceToType (same-type passthrough or
//     same-bit-width bitcast; anything else materializes the base).
//   - A VirtualRef entry forwards the load to the inner virtual's allocation
//     and installs a virtual alias, or — if the inner already materialized
//     — forwards to the materialized pointer with a scalar alias.
//   - A MaterializedRef entry forwards the load to the materialized value.
void Analyzer::processLoad(LoadInst *LI) {
  Value *Ptr = LI->getPointerOperand();

  auto BaseID = jeandle::pea::resolveVirtualRef(Ptr, CurrentState, Aliases, DL);
  if (!BaseID)
    return;

  jeandle::VirtualObject &VObj = *Result.VirtualObjects[*BaseID];

  if (!Eligible.lookup(*BaseID)) {
    // The load itself stays real. Preserve every reaching eliminated
    // definition whose tracked byte range overlaps this access; an unresolved
    // access may read any tracked cell, so it observes all definitions.
    std::optional<int64_t> Offset = resolveAccess(Ptr, *BaseID);
    TypeSize LoadSize = DL.getTypeStoreSize(LI->getType());
    if (!Offset || LoadSize.isScalable() || LoadSize.getFixedValue() == 0 ||
        LoadSize.getFixedValue() > std::numeric_limits<uint8_t>::max()) {
      observeFieldDefinitions(*BaseID, FieldDefinitions);
      return;
    }
    uint8_t LoadBytes = static_cast<uint8_t>(LoadSize.getFixedValue());
    for (const jeandle::VirtualObject::FieldDesc &Field : VObj.Fields) {
      std::optional<bool> Overlap = Field.overlaps(*Offset, LoadBytes);
      if (!Overlap || *Overlap)
        observeFieldDefinition(*BaseID, Field.Offset, FieldDefinitions);
    }
    return;
  }

  // LLVM volatile is an observable access (and can denote MMIO); it is not
  // Java volatile. Preserve the load exactly and materialize its virtual
  // receiver immediately before it.
  if (LI->isVolatile()) {
    materializeAt(*BaseID, LI, MatReason::Unhandled);
    return;
  }

  // Array length load (e.g. a bounds check): the length lives in the array
  // header at ArrayLengthOffset, which resolveAccess's header guard rejects as
  // a non-Java-field offset, so the load would otherwise materialize the whole
  // array at the load (every array access has a bounds check, so without this
  // fold no array could stay virtual across a bounds check). Fold the
  // length load to the known ArrayLength constant. Sound even if the array
  // later becomes materialized: the real array has exactly ArrayLength
  // elements, so the constant matches its header length.
  if (VObj.isArray() && LI->getType()->isIntegerTy(32)) {
    if (auto LenOff = jeandle::pea::resolveFieldOffset(Ptr, DL)) {
      if (*LenOff == VMConsts.arrayLengthOffset()) {
        auto E = std::make_unique<jeandle::ReplaceLoadEffect>();
        E->Block = LI->getParent();
        E->Target = LI;
        E->Replacement =
            ConstantInt::get(LI->getType(), (uint64_t)VObj.ArrayLength);
        E->SeqNo = Result.nextSeqNo();
        E->setMutationOwner(*BaseID);
        Result.addBlockEffect(std::move(E));
        return;
      }
    }
  }

  // Shared offset resolution; see resolveAccess.
  std::optional<int64_t> Offset = resolveAccess(Ptr, *BaseID);
  if (!Offset) {
    checkRawHeaderAccess(LI, Ptr, *BaseID);
    // Unresolvable offset (symbolic array index, non-constant GEP, header):
    // the load cannot be tracked. Materialize the base AT the load: tracked
    // stores are replayed onto OrigAlloc right before LI, and OrigAlloc is
    // kept (PartiallyEscapes), so the derived address stays valid. The load
    // survives as a real load.
    materializeAt(*BaseID, LI, MatReason::Unhandled);
    return;
  }

  Type *LoadTy = LI->getType();

  // Locate the FieldDesc whose recorded range contains the load. We detect the
  // relationship between the load and the stored slot so we can bail correctly:
  // a load that straddles slot boundaries (overlaps without being contained)
  // forces materialization here, and a load contained in a wider slot but at a
  // nonzero within-slot offset is a sub-slot read bailed on below (see
  // WithinSlotByteOff). Loads that exactly cover the slot, or read it at the
  // same offset, proceed to coerceToType.
  TypeSize LoadSize =
      LoadTy->isSized() ? DL.getTypeSizeInBits(LoadTy) : TypeSize::getFixed(0);
  // Unknown-size (unsized type) or oversized load (does not fit the uint8_t
  // field-width model — same guard as getOrCreateFieldIndex): cannot be
  // modelled — materialize the base at the load rather than mis-model the
  // access.
  if (LoadSize.isScalable()) {
    materializeAt(*BaseID, LI, MatReason::Unhandled);
    return;
  }
  uint64_t LoadBits = LoadSize.getFixedValue();
  if (LoadBits == 0 || LoadBits > 255 * 8) {
    materializeAt(*BaseID, LI, MatReason::Unhandled);
    return;
  }
  uint8_t LoadByteSize = static_cast<uint8_t>((LoadBits + 7) / 8);
  std::optional<int64_t> CheckedLoadEnd =
      jeandle::pea::checkedOffsetAdd(*Offset, LoadByteSize);
  if (!CheckedLoadEnd) {
    materializeAt(*BaseID, LI, MatReason::Unhandled);
    return;
  }
  int64_t LoadEnd = *CheckedLoadEnd;
  int64_t EntryOffset = *Offset;
  bool OverlapsNoncontained = false;
  // Fields are sorted by Offset; linear scan is fine for the small per-object
  // field counts we see in practice.
  for (const auto &F : VObj.Fields) {
    std::optional<int64_t> CheckedFieldEnd =
        jeandle::pea::checkedOffsetAdd(F.Offset, F.ByteSize);
    if (!CheckedFieldEnd) {
      materializeAt(*BaseID, LI, MatReason::Unhandled);
      return;
    }
    int64_t FEnd = *CheckedFieldEnd;
    if (FEnd <= *Offset)
      continue;
    if (F.Offset >= LoadEnd)
      break;
    // Some overlap. Contained iff F covers [*Offset, LoadEnd).
    if (F.Offset <= *Offset && FEnd >= LoadEnd) {
      EntryOffset = F.Offset;
    } else {
      OverlapsNoncontained = true;
    }
    break;
  }
  if (OverlapsNoncontained) {
    // TODO(unsafe-inliner): see the access dispatch (processStore/processLoad).
    // Any straddling load conservatively forces materialization at the load.
    materializeAt(*BaseID, LI, MatReason::Unhandled);
    return;
  }

  // A nonzero within-slot offset means the load reads PART of a wider stored
  // field (a sub-slot / "incomplete field" read). Such partial-field reads are
  // not folded, so we bail to materialization. The bail runs after the
  // Unknown/default-value fold below, so a sub-slot read of a never-written
  // field still folds to its default (zero for every primitive).
  std::optional<int64_t> WithinSlotByteOff =
      jeandle::pea::checkedOffsetSub(*Offset, EntryOffset);
  if (!WithinSlotByteOff) {
    materializeAt(*BaseID, LI, MatReason::Unhandled);
    return;
  }

  const jeandle::FieldValue *Existing = nullptr;
  auto It = FieldStates.find(*BaseID);
  if (It != FieldStates.end()) {
    auto It2 = It->second.find(EntryOffset);
    if (It2 != It->second.end())
      Existing = &It2->second;
  }
  if (Existing)
    observeFieldDefinition(*BaseID, EntryOffset, FieldDefinitions);

  // FieldValue::unknown() is the local default initializer used transiently
  // in merge/Case-C synthesis (see the P.AllSame / PerPredFVs paths), but it
  // is NEVER stored into FieldStates for a real (base, offset) entry — only
  // Scalar / VirtualRef / MaterializedRef reach the map. So a hit here is
  // always a concrete value; the only "no tracked value" case is the miss
  // (!Existing), which folds the load to the field's Java default.
  if (!Existing) {
    // Default value for a never-written field.
    Constant *Def = jeandle::FieldValue::defaultFor(LoadTy);
    auto E = std::make_unique<jeandle::ReplaceLoadEffect>();
    E->Block = LI->getParent();
    E->Target = LI;
    E->Replacement = Def;
    E->SeqNo = Result.nextSeqNo();
    E->setMutationOwner(*BaseID);
    Result.addBlockEffect(std::move(E));
    Aliases.addScalarAlias(LI, Def);
    return;
  }

  // Sub-slot read of a non-Unknown field: a partial-field load is not folded
  // (see WithinSlotByteOff above). Force the object to materialize so the
  // original load survives in IR.
  if (*WithinSlotByteOff != 0) {
    materializeAt(*BaseID, LI, MatReason::Unhandled);
    return;
  }

  if (Existing->isScalar()) {
    Value *V = Existing->getScalar();
    // Coerce to LoadTy: same-type passthrough or same-bit-width primitive↔
    // primitive reinterpret (bitcast). Pointer↔primitive, cross-AS pointer
    // pairs, and any cross-width mismatch (narrowing/widening) cannot be
    // folded: a kind/width-mismatched load materializes the object at the
    // load, keeping the tracked slot's stable kind/width intact.
    Value *Coerced = coerceToType(V, LoadTy, LI);
    if (!Coerced) {
      materializeAt(*BaseID, LI, MatReason::Unhandled);
      return;
    }
    auto E = std::make_unique<jeandle::ReplaceLoadEffect>();
    E->Block = LI->getParent();
    E->Target = LI;
    E->Replacement = Coerced;
    E->SeqNo = Result.nextSeqNo();
    E->setMutationOwner(*BaseID);
    Result.addBlockEffect(std::move(E));
    Aliases.addScalarAlias(LI, Coerced);
    return;
  }

  if (Existing->isVirtualRef()) {
    // Nested-virtual load: loading a field whose tracked value is another
    // virtual yields that other virtual (still virtual!) and forwards the
    // load to it. Forward the load to the inner virtual's allocation
    // Value and install a virtual alias from the load to
    // InnerID so downstream access handlers (foldArrayLength, foldLoadKlass,
    // etc.) and the generic escape detection see %loaded as a reference to the
    // inner virtual. If the inner later materializes / escapes, the
    // analyzer's existing nested-virtual machinery (a) rewrites every
    // other tracking site (FieldStates, alias map) to the materialized
    // pointer, and (b) at transform time, applyMaterialize records
    // OrigAlloc (reused) as the materialized value; the field-replay value
    // is OrigAlloc (applyMaterialize records it in MaterializedReceiverOf for a
    // sibling lock replay — see the materialization model in
    // PartialEscapeTransform.cpp).
    // (Belt-and-suspenders: the ReplaceLoad handler also resolves
    // E.Replacement through OrigAlloc directly.)
    jeandle::ObjectID InnerID = Existing->getVirtualRef();

    if (!Eligible.lookup(InnerID)) {
      // The inner was abandoned by some upstream decision — its alloc
      // will survive in IR, but we should not silently keep forwarding to
      // it for the outer because forwarding can mask a missing
      // materialization. Bail conservatively on the outer.
      markIneligible(*BaseID);
      return;
    }

    const jeandle::ObjectState *InnerOS =
        CurrentState.getObjectStateOptional(InnerID);
    if (!InnerOS) {
      // The inner's ObjectState isn't live in this block (shouldn't happen
      // for a VirtualRef field entry that was inherited alongside the
      // outer, but defend). Bail on the outer only; do not poison the
      // inner — it may be cleanly virtualizable on other paths.
      markIneligible(*BaseID);
      return;
    }

    Value *Repl = nullptr;
    if (InnerOS->isMaterialized()) {
      // Defensive: the analyzer rewrites VirtualRef → MaterializedRef on
      // every materialization site, so a VirtualRef field entry whose
      // inner has flipped to Materialized at this point would normally be
      // stale. If we still observe it, fall back to the materialized
      // pointer — same shape as the MaterializedRef branch below.
      Repl = InnerOS->getMaterializedValue();
    } else {
      jeandle::VirtualObject &InnerVO = *Result.VirtualObjects[InnerID];
      Repl = InnerVO.AllocationCall;
    }
    // The fallback must yield a value that exists in IR. Keep the outer object
    // real if the ObjectState invariant is violated.
    if (!Repl ||
        (isa<Instruction>(Repl) && !cast<Instruction>(Repl)->getParent())) {
      markIneligible(*BaseID);
      return;
    }

    // Type-compatibility. For ordinary reference loads, both LoadTy and the
    // inner allocation are `ptr addrspace(1)` and coerceToType returns Repl
    // unchanged. Cross-address-space or ptr↔primitive mismatch materializes
    // the outer at the load (stable-slot-kind invariant). (Sub-slot pointer
    // loads were already rejected by the WithinSlotByteOff bail above.) We
    // don't poison InnerID because other paths may still be able to
    // virtualize it.
    Value *Coerced = coerceToType(Repl, LoadTy, LI);
    if (!Coerced) {
      materializeAt(*BaseID, LI, MatReason::Unhandled);
      return;
    }

    auto E = std::make_unique<jeandle::ReplaceLoadEffect>();
    E->Block = LI->getParent();
    E->Target = LI;
    E->Replacement = Coerced;
    E->SeqNo = Result.nextSeqNo();
    E->setMutationOwner(*BaseID);
    Result.addBlockEffect(std::move(E));

    // Install the virtual alias only when the inner is still virtual at
    // this point. If we fell back to a materialized pointer above, mirror
    // the MaterializedRef branch and register a scalar alias so downstream
    // resolveVirtualRef queries see through to the materialized value.
    if (InnerOS->isMaterialized())
      Aliases.addScalarAlias(LI, Coerced);
    else
      Aliases.addVirtualAlias(LI, InnerID, /*IsWholeObject=*/true);
    return;
  }

  if (Existing->isMaterializedRef()) {
    // A virtual's reference field carries a materialized pointer (e.g.
    // produced by a field-PHI synthesis at a merge block). Forward the load
    // to the materialized value, matching the Scalar handler.
    Value *V = Existing->getMaterialized();
    if (!V) {
      markIneligible(*BaseID);
      return;
    }
    // A materialized ref slot can only be loaded back as a pointer (and in
    // practice, since LLVM 17 uses opaque pointers, only as the same
    // ptr-AS). coerceToType fails on ptr↔primitive (stable-slot-kind) and
    // cross-AS pointer pairs — materialize at the load in that case.
    // (Partial pointer loads were already rejected by the WithinSlotByteOff
    // bail above.)
    Value *Coerced = coerceToType(V, LoadTy, LI);
    if (!Coerced) {
      materializeAt(*BaseID, LI, MatReason::Unhandled);
      return;
    }
    auto E = std::make_unique<jeandle::ReplaceLoadEffect>();
    E->Block = LI->getParent();
    E->Target = LI;
    E->Replacement = Coerced;
    E->SeqNo = Result.nextSeqNo();
    E->setMutationOwner(*BaseID);
    Result.addBlockEffect(std::move(E));
    Aliases.addScalarAlias(LI, Coerced);
    return;
  }

  // Should be unreachable; FieldValue::Tag is a closed enum.
  markIneligible(*BaseID);
}

// ---------------------------------------------------------------------------
// JavaOp folding on virtual receivers.
// ---------------------------------------------------------------------------

void Analyzer::emitReplaceCall(CallBase *CB, Value *Replacement,
                               jeandle::ObjectID ID) {
  // PEA only folds Jeandle JavaOp intrinsics (CallInst/InvokeInst); every
  // caller is gated on an isJeandle* name predicate, which a CallBrInst
  // (inline-asm-with-goto, no called function) can never satisfy. Fail fast
  // at the producer so a callbr can never become a ReplaceCall target whose
  // successor edges ReplaceCallEffect::apply would mishandle.
  assert(!isa<CallBrInst>(CB) &&
         "PEA ReplaceCall targets are folded Jeandle "
         "JavaOps (CallInst/InvokeInst); a CallBrInst cannot reach here");
  auto E = std::make_unique<jeandle::ReplaceCallEffect>();
  E->Block = CB->getParent();
  E->Target = CB;
  E->Replacement = Replacement;
  E->SeqNo = Result.nextSeqNo();
  E->setMutationOwner(ID);
  Result.addBlockEffect(std::move(E));
  // Scalar-alias non-void call values so downstream resolveVirtualRef queries
  // (e.g. another JavaOp later in the same block whose operand is the call
  // result) see through to the replacement constant. Void JavaOps can use a
  // null Replacement to request deletion only.
  if (Replacement)
    Aliases.addScalarAlias(CB, Replacement);
}

std::optional<bool> Analyzer::evalSubtypeRelation(uintptr_t SubKlass,
                                                  uintptr_t SuperKlass) {
  const jeandle::VMCallbacks *CB = jeandle::getVMCallbacks();
  if (!CB || !CB->IsSubtype || !CB->IsInterface)
    return std::nullopt;
  if (CB->IsSubtype(SubKlass, SuperKlass))
    return true;
  // Virtual objects always have an exact, concrete klass (we know the
  // allocation site). Pass Exact=true to areKlassesIncompatible.
  if (jeandle::areKlassesIncompatible(SubKlass, /*Exact=*/true, SuperKlass))
    return false;
  return std::nullopt;
}

bool Analyzer::foldArrayLength(CallBase *CB) {
  if (CB->arg_size() < 1)
    return false;
  auto BaseID = jeandle::pea::resolveVirtualRef(CB->getArgOperand(0),
                                                CurrentState, Aliases, DL);
  if (!BaseID)
    return false;
  if (!Eligible.lookup(*BaseID))
    return false;

  jeandle::VirtualObject &VObj = *Result.VirtualObjects[*BaseID];
  if (!VObj.isArray())
    return false;
  Type *I32 = Type::getInt32Ty(F.getContext());
  Constant *Len = ConstantInt::get(I32, VObj.ArrayLength);
  emitReplaceCall(CB, Len, *BaseID);
  return true;
}

bool Analyzer::foldLoadKlass(CallBase *CB) {
  if (CB->arg_size() < 1)
    return false;
  auto BaseID = jeandle::pea::resolveVirtualRef(CB->getArgOperand(0),
                                                CurrentState, Aliases, DL);
  if (!BaseID)
    return false;
  if (!Eligible.lookup(*BaseID))
    return false;
  jeandle::VirtualObject &VObj = *Result.VirtualObjects[*BaseID];
  if (VObj.Klass == 0)
    return false;
  LLVMContext &Ctx = F.getContext();
  Type *I64 = Type::getInt64Ty(Ctx);
  Type *PtrTy = PointerType::get(Ctx, jeandle::AddrSpace::CHeapAddrSpace);
  Constant *KlassAsInt = ConstantInt::get(I64, VObj.Klass);
  Constant *KlassPtr = ConstantExpr::getIntToPtr(KlassAsInt, PtrTy);
  emitReplaceCall(CB, KlassPtr, *BaseID);
  return true;
}

bool Analyzer::foldGetClass(CallBase *CB) {
  // jeandle.get_class(oop) -> ptr addrspace(1) (the java.lang.Class mirror).
  // For a virtual receiver whose exact klass is statically known, the Class
  // mirror is a compile-time constant, so fold the call instead of forcing
  // the receiver to materialize (the conservative fall-through). The GC-safe
  // mirror load is built at transform time (ReplaceCallEffect::OopHandleId,
  // see createConstOopLoad); the analyzer records only the mirror's oop id so
  // it stays side-effect-free. No scalar alias is needed: no downstream
  // JavaOp consumes a Class mirror (JavaHeap) operand, and a virtual's
  // getClass() result is a constant, not a virtual.
  if (CB->arg_size() < 1)
    return false;
  auto BaseID = jeandle::pea::resolveVirtualRef(CB->getArgOperand(0),
                                                CurrentState, Aliases, DL);
  if (!BaseID)
    return false;
  if (!Eligible.lookup(*BaseID))
    return false;
  jeandle::VirtualObject &VObj = *Result.VirtualObjects[*BaseID];
  if (VObj.Klass == 0)
    return false;
  const jeandle::VMCallbacks *VMCB = jeandle::getVMCallbacks();
  if (!VMCB || !VMCB->GetJavaMirror)
    return false; // offline (no callback log) or unsupported: bail (sound).
  int MirrorOopId = VMCB->GetJavaMirror(VObj.Klass);
  if (MirrorOopId < 0)
    return false;
  auto E = std::make_unique<jeandle::ReplaceCallEffect>();
  E->Block = CB->getParent();
  E->Target = CB;
  E->Replacement = nullptr; // built in apply() from OopHandleId.
  E->OopHandleId = MirrorOopId;
  E->SeqNo = Result.nextSeqNo();
  E->setMutationOwner(*BaseID);
  Result.addBlockEffect(std::move(E));
  return true;
}

bool Analyzer::foldCheckCast(CallBase *CB) {
  // jeandle.checkcast itself is lower-phase="0" by design: its expansion
  // exposes a null check (foldICmpEquality) and a jeandle.check_instanceof
  // call (lower-phase="1"), which is the subtype-check op this fold sees in
  // production. The direct jeandle.checkcast form is only reachable from lit
  // tests.
  if (CB->arg_size() < 2)
    return false;
  uintptr_t SuperK = jeandle::extractKlassConstant(CB->getArgOperand(0));
  if (SuperK == 0)
    return false;
  auto BaseID = jeandle::pea::resolveVirtualRef(CB->getArgOperand(1),
                                                CurrentState, Aliases, DL);
  if (!BaseID)
    return false;
  if (!Eligible.lookup(*BaseID))
    return false;
  jeandle::VirtualObject &VObj = *Result.VirtualObjects[*BaseID];
  if (VObj.Klass == 0)
    return false;
  auto Folded = evalSubtypeRelation(VObj.Klass, SuperK);
  if (!Folded)
    return false;
  Constant *Res = *Folded ? ConstantInt::getTrue(CB->getType())
                          : ConstantInt::getFalse(CB->getType());
  emitReplaceCall(CB, Res, *BaseID);
  return true;
}

bool Analyzer::foldInstanceOf(CallBase *CB) {
  // jeandle.instanceof itself is lower-phase="0" by design: its expansion
  // exposes a null check (foldICmpEquality) and a jeandle.check_instanceof
  // call (lower-phase="1", handled by foldCheckCast). The direct
  // jeandle.instanceof form is only reachable from lit tests.
  if (CB->arg_size() < 2)
    return false;
  uintptr_t SuperK = jeandle::extractKlassConstant(CB->getArgOperand(0));
  if (SuperK == 0)
    return false;
  auto BaseID = jeandle::pea::resolveVirtualRef(CB->getArgOperand(1),
                                                CurrentState, Aliases, DL);
  if (!BaseID)
    return false;
  if (!Eligible.lookup(*BaseID))
    return false;
  jeandle::VirtualObject &VObj = *Result.VirtualObjects[*BaseID];
  if (VObj.Klass == 0)
    return false;
  // Virtual objects are non-null by construction, so we can collapse the
  // null-check inside instanceof and reduce to a pure subtype query.
  auto Folded = evalSubtypeRelation(VObj.Klass, SuperK);
  if (!Folded)
    return false;
  Type *I32 = Type::getInt32Ty(F.getContext());
  Constant *Res = ConstantInt::get(I32, *Folded ? 1 : 0);
  emitReplaceCall(CB, Res, *BaseID);
  return true;
}

// Absolute bytecode lock depth of a monitorenter: the CFG-relative depth
// recorded in MonitorDepth.EnterRelativeDepth plus the function-entry offset
// (nonzero only for OSR roots). Returns nullopt when the depth model is
// invalid, the enter was not recorded, or the absolute depth is not
// representable.
std::optional<uint32_t> Analyzer::getLockDepth(CallBase *CB) const {
  if (!MonitorDepth.Valid)
    return std::nullopt;
  auto It = MonitorDepth.EnterRelativeDepth.find(CB);
  if (It == MonitorDepth.EnterRelativeDepth.end())
    return std::nullopt;
  int64_t RelativeDepth = It->second;
  uint64_t AbsoluteDepth = MonitorDepth.EntryDepth;
  if (RelativeDepth < 0) {
    if (RelativeDepth == std::numeric_limits<int64_t>::min() ||
        static_cast<uint64_t>(-RelativeDepth) > AbsoluteDepth)
      return std::nullopt;
    AbsoluteDepth -= static_cast<uint64_t>(-RelativeDepth);
  } else {
    AbsoluteDepth += static_cast<uint64_t>(RelativeDepth);
  }
  if (AbsoluteDepth > std::numeric_limits<uint32_t>::max())
    return std::nullopt;
  return static_cast<uint32_t>(AbsoluteDepth);
}

// Strict-lock cascade: before a REAL monitorenter whose bytecode depth is D,
// materialize every still-virtual VO holding an elided lock with a strictly
// shallower minimum depth (LiveLockEnters[id].front() is the outermost /
// minimum-depth live enter). This keeps each such VO's re-emitted lock below
// this real lock on the lightweight-locking thread lock stack, preserving
// lexical nesting.
void Analyzer::materializeVirtualLocksBefore(CallBase *MonEnter) {
  assert(StrictLockOrder && "caller gates on StrictLockOrder");
  auto LockDepth = getLockDepth(MonEnter);
  if (!LockDepth)
    return;
  SmallVector<jeandle::ObjectID, 4> Cascade;
  for (auto &Kv : LiveLockEnters) {
    if (Kv.second.empty())
      continue;
    if (Kv.second.front().BytecodeDepth < *LockDepth)
      Cascade.push_back(Kv.first);
  }
  llvm::sort(Cascade); // deterministic
  if (Cascade.empty())
    return;

  // Every candidate selected for one real monitorenter is one physical
  // strict-order batch. Keep the root plan open across the complete batch so
  // final eligibility cannot retain an earlier candidate's replay after a
  // later candidate's original enter revives.
  const bool IsPlanRoot =
      ActiveMaterializationPlanID == jeandle::MaterializeEffect::InvalidPlanID;
  if (IsPlanRoot)
    ActiveMaterializationPlanID = NextMaterializationPlanID++;
  auto FinishPlan = llvm::make_scope_exit([&] {
    if (IsPlanRoot)
      ActiveMaterializationPlanID = jeandle::MaterializeEffect::InvalidPlanID;
  });
  for (jeandle::ObjectID OID : Cascade)
    materializeAt(OID, MonEnter, MatReason::Cascade);
}

// Fold a monitorenter against a virtual receiver: record the lock on the
// VO's state (addLock) and emit a ReplaceCall(null) so the transform DELETES
// the original monitorenter call. If the object later materializes, the
// surviving (unbalanced) enters are captured into the Materialize effect's
// Locks list (captureMaterializedLocks via
// MaterializeContext::CaptureLocksIntoEffect) and RE-EMITTED at the
// materialize point by applyMaterialize, sorted ascending by lock depth.
// The matching monitorexit that follows the escape is NOT folded (the
// receiver is already materialized by then) and survives to release the
// re-emitted lock.
//
// See ensureMaterialized's lock-capture block and applyMaterialize's re-emit
// loop for the capture + re-emit mechanism.
bool Analyzer::foldMonitorEnter(CallBase *CB) {
  if (!LockEliminationEnabled)
    return false;

  if (!MonitorDepth.Valid)
    return false;
  if (CB->arg_size() < 1)
    return false;
  auto BaseID = jeandle::pea::resolveVirtualRef(CB->getArgOperand(0),
                                                CurrentState, Aliases, DL);
  if (!BaseID)
    return false;

  // The receiver resolves to a VO that an earlier decision already abandoned
  // (resolveVirtualRef does not consult Eligible). Eliding this enter would
  // be revoked at commit anyway, so the enter survives as a REAL lock — but
  // the strict-order cascade below (fold path) and in processInstruction
  // (non-virtual-receiver path) both key off properties this call no longer
  // has, so without an explicit cascade here a shallower still-virtual lock
  // would be re-emitted AFTER this real enter, inverting the runtime lock
  // stack. Return false so the call survives (the generic path then
  // materializes any other virtual operand).
  if (!Eligible.lookup(*BaseID)) {
    if (StrictLockOrder)
      materializeVirtualLocksBefore(CB);
    return false;
  }

  auto NewBytecodeDepth = getLockDepth(CB);
  if (!NewBytecodeDepth)
    return false;

  // Lock confinement: the lock counter is balanced per-block at commit
  // time. A monitorenter on a virtual is always safe to provisionally
  // elide; if the matching monitorexit is missing, commit() will flip the
  // virtual to ineligible and the effects will be dropped.
  ++LockCounts[*BaseID];
  // Push the elided enter onto the live stack so materializeAt can undo
  // only the unbalanced enters along this path if the object later escapes.
  // BytecodeDepth is the stable CFG-derived ordering key used by the cascade
  // and merge-time stack-identity comparisons.
  auto &Stack = LiveLockEnters[*BaseID];
  // Depth monotonicity invariant (asserted in ObjectState::addLock): nested
  // monitorenters acquire strictly increasing bytecode depth, so a newly
  // pushed enter must be strictly deeper than the current innermost (back)
  // live enter on this VO.
  assert(Stack.empty() || *NewBytecodeDepth > Stack.back().BytecodeDepth);
  Stack.push_back({CB, *NewBytecodeDepth});
  // Keep the per-VO ObjectState::Locks mirror in lockstep with the analyzer-
  // side DenseMap. There is no separate instruction-order counter: structural
  // ObjectState equivalence (used by merge-time shallowEquals and the loop-
  // fixpoint exitDataEquivalent convergence path) compares Call+BytecodeDepth.
  if (CurrentState.hasObjectState(*BaseID)) {
    jeandle::ObjectState &OS =
        CurrentState.getObjectStateForModification(*BaseID);
    if (OS.isVirtual())
      OS.addLock({CB, *NewBytecodeDepth});
  }
  // Monitor JavaOps return void (the fast/slow dispatch lives inside the
  // JavaOp body, invisible to PEA), so there is no result to replace: emit a
  // null Replacement and let the transform erase the (always unused) call.
  emitReplaceCall(CB, nullptr, *BaseID);
  return true;
}

bool Analyzer::foldMonitorExit(CallBase *CB) {
  if (!LockEliminationEnabled)
    return false;

  if (!MonitorDepth.Valid)
    return false;
  if (CB->arg_size() < 1)
    return false;
  auto BaseID = jeandle::pea::resolveVirtualRef(CB->getArgOperand(0),
                                                CurrentState, Aliases, DL);
  if (!BaseID)
    return false;
  if (!Eligible.lookup(*BaseID))
    return false;
  auto It = LockCounts.find(*BaseID);
  if (It == LockCounts.end() || It->second == 0) {
    // Unbalanced monitorexit (release without acquire on this virtual). Mark
    // the virtual ineligible and let the generic escape path keep the call.
    markIneligible(*BaseID);
    return false;
  }
  --It->second;
  // Pop the matching enter off the live stack. The pair is now balanced
  // and both calls' ReplaceCall(null) effects stay in the ledger — the
  // transform erases both calls when it applies them.
  auto SIt = LiveLockEnters.find(*BaseID);
  assert(SIt != LiveLockEnters.end() && !SIt->second.empty() &&
         "live stack must be non-empty when LockCount > 0");
  SIt->second.pop_back();
  // Mirror the pop on ObjectState::Locks so the on-VO Locks view
  // stays consistent with the analyzer-side LiveLockEnters for any caller
  // that introspects the ObjectState directly (e.g. the loop-fixpoint
  // exitDataEquivalent convergence check or merge-time shallowEquals).
  if (CurrentState.hasObjectState(*BaseID)) {
    jeandle::ObjectState &OS =
        CurrentState.getObjectStateForModification(*BaseID);
    if (OS.isVirtual() && OS.hasLocks())
      OS.removeLock();
  }
  // Monitor JavaOps return void, so there is no result to replace; see
  // foldMonitorEnter for why the null Replacement deletes the call.
  emitReplaceCall(CB, nullptr, *BaseID);
  return true;
}

bool Analyzer::foldArrayStoreCheck(CallBase *CB) {
  // jeandle.array_store_check(value, array). The op is read-only on the heap,
  // so a virtual base is NOT an escape when the check is ELIDED (provably
  // compatible / primitive element): the call is deleted, so no operand
  // reference survives.
  //
  // CONTRACT: when the check SURVIVES (cannot be proven elidable) it needs
  // real operands, so BOTH the array and any virtual value must materialize.
  // Such paths return FALSE so the generic escape path
  // (materializeAllVirtualOperands) handles every virtual operand. The only
  // return-true paths are the elisions below, where the call is deleted and
  // holds no surviving operand reference.
  if (CB->arg_size() < 2)
    return false; // malformed — let the generic path materialize any virtual.
  auto ArrayID = jeandle::pea::resolveVirtualRef(CB->getArgOperand(1),
                                                 CurrentState, Aliases, DL);
  if (!ArrayID)
    return false; // array not virtual — a virtual VALUE operand still escapes.
  if (!Eligible.lookup(*ArrayID))
    return false;
  jeandle::VirtualObject &ArrayObj = *Result.VirtualObjects[*ArrayID];

  const jeandle::VMCallbacks *VMCB = jeandle::getVMCallbacks();
  if (!VMCB || !VMCB->ArrayElementKlass)
    return false; // cannot prove elidable — survive + materialize.
  if (ArrayObj.Klass == 0)
    return false;

  uintptr_t ElementKlass = VMCB->ArrayElementKlass(ArrayObj.Klass);
  if (ElementKlass == 0) {
    // Primitive (type-array) element: array_store_check is a no-op on
    // primitive arrays (no covariant store check for primitives). Elide to
    // true. A primitive array's value is a primitive, never a virtual object,
    // and the elision deletes the call, so no operand reference survives.
    Constant *True = ConstantInt::getTrue(CB->getType());
    emitReplaceCall(CB, True, *ArrayID);
    return true;
  }

  // Object[] element: compare the value's klass against the element klass.
  Value *Val = CB->getArgOperand(0);
  // A null value can be stored into any Object[] — elide the check. Eliding
  // deletes the call, so the null operand survives nowhere.
  if (isa<ConstantPointerNull>(Val)) {
    Constant *True = ConstantInt::getTrue(CB->getType());
    emitReplaceCall(CB, True, *ArrayID);
    return true;
  }
  uintptr_t ValueKlass = 0;
  if (auto ValueID =
          jeandle::pea::resolveVirtualRef(Val, CurrentState, Aliases, DL)) {
    if (!Eligible.lookup(*ValueID))
      return false;
    // Virtual values carry an exact, concrete klass.
    ValueKlass = Result.VirtualObjects[*ValueID]->Klass;
  } else {
    // Fall back to attribute / metadata sharpening for non-virtual values.
    jeandle::JavaType JT = jeandle::getJavaType(Val);
    ValueKlass = JT.Klass;
  }

  if (ValueKlass == 0) {
    // Every Java reference is assignable to java.lang.Object. This is the one
    // reference-array case that does not require klass information for the
    // stored value.
    if (VMCB->IsObjectKlass && VMCB->IsObjectKlass(ElementKlass)) {
      Constant *True = ConstantInt::getTrue(CB->getType());
      emitReplaceCall(CB, True, *ArrayID);
      return true;
    }
    return false; // unknown value klass — cannot prove elidable.
  }

  auto Folded = evalSubtypeRelation(ValueKlass, ElementKlass);
  if (!Folded)
    return false; // indeterminate subtype — cannot prove elidable.

  if (*Folded) {
    // Provably compatible — elide. The value does not escape through the
    // (deleted) check.
    Constant *True = ConstantInt::getTrue(CB->getType());
    emitReplaceCall(CB, True, *ArrayID);
    return true;
  }
  // Provably incompatible: at runtime this throws ArrayStoreException. The
  // surviving check must inspect the real value and array klass — materialize
  // both (return false -> generic escape path).
  return false;
}

bool Analyzer::foldPostBarrier(CallBase *CB) {
  if (CB->arg_size() < 1)
    return false;
  auto BaseID = jeandle::pea::resolveVirtualRef(CB->getArgOperand(0),
                                                CurrentState, Aliases, DL);
  if (!BaseID)
    return false;
  if (!Eligible.lookup(*BaseID))
    return false;

  // A post barrier for a store into a virtual object has no concrete card to
  // mark. The store is replayed as initialization when the object is
  // materialized, so the original barrier must not survive with the old slot
  // address.
  emitReplaceCall(CB, nullptr, *BaseID);
  return true;
}

bool Analyzer::foldCheckIfValueBased(CallBase *CB) {
  // jeandle.check_if_value_based(oop) -> i1.  Java emits this around
  // monitorenter on receivers whose static type could be a value-based class
  // (e.g. java.lang.Long), so that the runtime raises a
  // DiagnoseSyncOnValueBasedClasses warning when the dynamic klass is in fact
  // value-based.
  //
  // Fold logic: if the exact runtime class is known, the check collapses to
  // a compile-time constant. For a VIRTUAL receiver:
  //
  //   * VObj.Klass unknown (0)              -> bail (keep the call, virtual
  //                                            will materialize via the
  //                                            generic escape path).
  //   * IsValueBased(VObj.Klass) == true    -> force materialize. The runtime
  //                                            warning MUST observe a real
  //                                            oop; eliding it would change
  //                                            user-visible semantics.
  //   * IsValueBased(VObj.Klass) == false   -> elide the call (constant false).
  //                                            The virtual receiver is
  //                                            provably NOT value-based.
  if (CB->arg_size() < 1)
    return false;
  auto BaseID = jeandle::pea::resolveVirtualRef(CB->getArgOperand(0),
                                                CurrentState, Aliases, DL);
  if (!BaseID)
    return false;
  if (!Eligible.lookup(*BaseID))
    return false;
  jeandle::VirtualObject &VObj = *Result.VirtualObjects[*BaseID];
  if (VObj.Klass == 0) {
    // Klass unknown — cannot prove either direction. Fall through to the
    // generic-escape path so the virtual gets materialized and the original
    // runtime check survives on a real oop.
    return false;
  }
  const jeandle::VMCallbacks *VMCB = jeandle::getVMCallbacks();
  if (!VMCB || !VMCB->IsValueBased) {
    // No callback registered (offline tests without a callback log). Bail
    // conservatively so the virtual materializes.
    return false;
  }
  if (VMCB->IsValueBased(VObj.Klass)) {
    // The dynamic klass IS value-based: HotSpot's runtime warning hook for
    // DiagnoseSyncOnValueBasedClasses must observe a real oop. Drop this
    // virtual's eligibility — commit() will discard every recorded effect
    // for it and the original allocation + check call stay in IR, where
    // the call ends up operating on the materialized pointer. Matches the
    // foldArrayStoreCheck "unknown value klass" conservative path.
    markIneligible(*BaseID);
    return true;
  }
  // Provably non-value-based: fold the check to false. The query against
  // an exact (virtualized) klass that does not carry the ValueBased marker
  // canonicalizes to false.
  Constant *False = ConstantInt::getFalse(CB->getType());
  emitReplaceCall(CB, False, *BaseID);
  return true;
}

bool Analyzer::foldRegisterFinalizerIfNeeded(CallBase *CB) {
  // jeandle.register_finalizer_if_needed(oop) -> void.
  //
  // The JavaOp's default lowering preserves HotSpot semantics by checking the
  // receiver klass finalizer bit and calling SharedRuntime_register_finalizer
  // only when needed. Finalizability is resolved at the allocation site:
  // processAllocation (new_instance handling) refuses to virtualize any
  // instance whose exact klass has a finalizer, so such an object stays
  // materialized and this call survives to be lowered normally. A virtual
  // receiver reaching this fold is therefore non-finalizable by construction
  // — delete the provably-no-op call without forcing the object header to
  // materialize.
  if (CB->arg_size() < 1)
    return false;
  auto BaseID = jeandle::pea::resolveVirtualRef(CB->getArgOperand(0),
                                                CurrentState, Aliases, DL);
  if (!BaseID)
    return false;
  if (!Eligible.lookup(*BaseID))
    return false;
  jeandle::VirtualObject &VObj = *Result.VirtualObjects[*BaseID];
  if (VObj.Klass == 0)
    return false;
  const jeandle::VMCallbacks *VMCB = jeandle::getVMCallbacks();
  if (!VMCB || !VMCB->HasFinalizer)
    return false;
  // A virtual receiver can only reach here if processAllocation virtualized
  // its allocation, and processAllocation (new_instance handling) refuses to
  // virtualize any instance whose exact klass has a finalizer. So by
  // construction the receiver is non-finalizable: the runtime check would
  // always be false and SharedRuntime_register_finalizer would never fire.
  // Assert that invariant, then delete the provably-no-op call so the
  // allocation can be eliminated.
  assert(!VMCB->HasFinalizer(VObj.Klass) &&
         "processAllocation must refuse finalizable klasses");
  emitReplaceCall(CB, nullptr, *BaseID);
  return true;
}

bool Analyzer::processIntrinsic(IntrinsicInst *II) {
  // Debug-only assert: PEA must run BEFORE RewriteStatepointsForGC. A
  // statepoint intrinsic appearing here means the pass scheduling has been
  // broken; bail loudly in debug, fall through (return false) in release —
  // safe, every statepoint operand is forced to materialize via the
  // hasVirtualInputs handler / generic-escape path.
  assert(II->getIntrinsicID() != Intrinsic::experimental_gc_statepoint &&
         II->getIntrinsicID() != Intrinsic::experimental_gc_relocate &&
         II->getIntrinsicID() != Intrinsic::experimental_gc_result &&
         "PEA must not run after RewriteStatepointsForGC");
  // assume: a non-escaping hint (returns void). Even when an operand bundle
  // such as "align"(ptr %vo, N) references a virtual, the bundle is an
  // informational claim about the pointer, not a real use that escapes it.
  // If the VO is NeverEscapes and gets RAUW'd to poison, the bundle operand
  // becomes poison too — but that is sound: assume returns void so poison
  // cannot propagate out, and the poisoned pointer has no other meaningful
  // use (any real use would have forced escape -> materialization -> a real,
  // non-poisoned pointer). The "align"(poison, N) fact is therefore vacuous
  // to every downstream pass. Kept as a no-op deliberately (see test
  // 76_assume_noop.ll); do NOT escalate to materialization.
  // Extended allowlist. None of these intrinsics produce a pointer with a
  // different identity than their argument, none mutate memory we care about,
  // and none cross the heap/abstract boundary — all safe to leave in IR
  // alongside a virtual without forcing escape.
  // var.annotation: TBAA-style debug annotation on a GLOBAL; the call returns
  //   void and its operand is a global pointer, never a heap virtual.
  // is.constant / expect / expect.with.probability: branch-prediction hints;
  //   their value-result is i1/iN derived from a primitive (the predicate or
  //   the comparison value), not from the virtual pointer's identity, so the
  //   virtual doesn't escape through them.
  // allow.runtime.check / allow.ubsan.check: similar — return i1.
  if (!jeandle::pea::isPEAHandledNonEscapingIntrinsic(II))
    return false;

  // pointer-identity-preserving intrinsics: each returns its first argument
  // (the same pointer, unchanged address). resolveVirtualRef does not recurse
  // through CallInst, so without help propagatePointerAlias would fall through
  // to materializeAllVirtualOperands and a downstream access through the
  // result would be untracked (the VO could be eliminated while the call's
  // result survives as a poison-derived pointer). Forward the argument's
  // virtual alias to the result instead.
  //   launder/strip.invariant.group: opaque identity barrier.
  //   ptr.annotation: returns the annotated pointer verbatim (NOT void — the
  //   var.annotation variant is the void one, handled above).
  switch (II->getIntrinsicID()) {
  case Intrinsic::launder_invariant_group:
  case Intrinsic::strip_invariant_group:
  case Intrinsic::ptr_annotation: {
    Value *Arg = II->getArgOperand(0);
    if (auto BaseID =
            jeandle::pea::resolveVirtualRef(Arg, CurrentState, Aliases, DL)) {
      auto WholeIdentity = jeandle::pea::resolveVirtualIdentity(
          Arg, CurrentState, Aliases, DL,
          jeandle::pea::VirtualIdentityMode::WholeObject);
      Aliases.addVirtualAlias(II, *BaseID,
                              /*IsWholeObject=*/WholeIdentity.isDefined());
    }
    // Whether or not the arg resolved, the call has no PEA escape effect.
    return true;
  }
  default:
    return true;
  }
}

bool Analyzer::foldICmpEquality(ICmpInst *ICmp) {
  // Equality compare against a virtual pointer folds. Virtual objects are
  // never null (by construction they track an in-flight alloc), so `icmp eq
  // virt, null` -> false, `icmp ne virt, null` -> true. Two virtuals:
  // different whole objects are distinct by allocation-site identity; the
  // same ObjectID compares byte offsets so two derived pointers into one
  // object are not conflated, and a symbolic offset materializes the object
  // at the icmp. A virtual vs. a non-null non-virtual operand folds to
  // distinct only under the target-relative external-value proof
  // (isProvablyDistinctFromVirtual): in particular, freeze poison/undef must
  // not be treated as distinct. Returns false when nothing can be proven or
  // a participating VO is already ineligible; the caller then runs the
  // generic escape path.
  if (!ICmp->isEquality())
    return false;
  Value *Op0 = ICmp->getOperand(0);
  Value *Op1 = ICmp->getOperand(1);
  auto R0 = jeandle::pea::resolveVirtualIdentity(
      Op0, CurrentState, Aliases, DL,
      jeandle::pea::VirtualIdentityMode::BaseObject);
  auto R1 = jeandle::pea::resolveVirtualIdentity(
      Op1, CurrentState, Aliases, DL,
      jeandle::pea::VirtualIdentityMode::BaseObject);
  std::optional<jeandle::ObjectID> V0;
  std::optional<jeandle::ObjectID> V1;
  if (R0.isDefined())
    V0 = R0.getObjectID();
  if (R1.isDefined())
    V1 = R1.getObjectID();
  auto W0 = jeandle::pea::resolveVirtualIdentity(
      Op0, CurrentState, Aliases, DL,
      jeandle::pea::VirtualIdentityMode::WholeObject);
  auto W1 = jeandle::pea::resolveVirtualIdentity(
      Op1, CurrentState, Aliases, DL,
      jeandle::pea::VirtualIdentityMode::WholeObject);
  auto IsWhole = [](const jeandle::pea::VirtualIdentityResult &Whole,
                    std::optional<jeandle::ObjectID> Base) {
    return Base && Whole.isDefined() && Whole.getObjectID() == *Base;
  };
  if ((V0 && !Eligible.lookup(*V0)) || (V1 && !Eligible.lookup(*V1)))
    return false;
  bool Op0IsNull = isa<ConstantPointerNull>(Op0);
  bool Op1IsNull = isa<ConstantPointerNull>(Op1);
  bool Folded = false;
  bool EqResult = false;
  jeandle::ObjectID BaseID = jeandle::InvalidObjectID;
  if (V0 && Op1IsNull && IsWhole(W0, V0)) {
    Folded = true;
    EqResult = false;
    BaseID = *V0;
  } else if (V1 && Op0IsNull && IsWhole(W1, V1)) {
    Folded = true;
    EqResult = false;
    BaseID = *V1;
  } else if (V0 && V1) {
    if (*V0 != *V1) {
      // Allocation-site identity proves distinctness only for the two whole
      // objects. Derived/one-past addresses from different allocations can
      // have the same numeric pointer value in LLVM IR.
      if (!IsWhole(W0, V0) || !IsWhole(W1, V1))
        return false;
      Folded = true;
      EqResult = false;
      BaseID = *V0;
    } else {
      // Same ObjectID. The base-identity resolution discarded any
      // derived-pointer byte offset (the GEP case chases the base), so two
      // operands of the SAME virtual at DIFFERENT offsets (e.g. %o vs
      // gep(%o,8)) would otherwise conflate to equal. Compare the byte
      // offsets too: equal -> equal addresses, different -> distinct. A
      // symbolic offset can't be proven either way: materialize the object
      // AT the icmp — reuse-OrigAlloc keeps both derived operands valid
      // (OrigAlloc dominates them and is kept alive by the surviving
      // Materialize effect), and the icmp survives as a real compare.
      auto O0 = jeandle::pea::resolveFieldOffset(Op0, DL);
      auto O1 = jeandle::pea::resolveFieldOffset(Op1, DL);
      if (!O0 || !O1) {
        materializeAt(*V0, ICmp, MatReason::Unhandled); // *V0 == *V1.
        return true;
      }
      Folded = true;
      EqResult = (*O0 == *O1);
      BaseID = *V0;
    }
  } else if (V0 && !V1 && !Op1IsNull && IsWhole(W0, V0) &&
             jeandle::pea::isProvablyDistinctFromVirtual(Op1, *V0, CurrentState,
                                                         Aliases, DL)) {
    Folded = true;
    EqResult = false;
    BaseID = *V0;
  } else if (V1 && !V0 && !Op0IsNull && IsWhole(W1, V1) &&
             jeandle::pea::isProvablyDistinctFromVirtual(Op0, *V1, CurrentState,
                                                         Aliases, DL)) {
    Folded = true;
    EqResult = false;
    BaseID = *V1;
  }
  if (!Folded)
    return false;
  bool IsEq = (ICmp->getPredicate() == ICmpInst::ICMP_EQ);
  bool FinalResult = IsEq ? EqResult : !EqResult;
  Constant *C = ConstantInt::get(ICmp->getType(), FinalResult ? 1 : 0);
  // Reuse ReplaceLoad: its handler does generic Instruction RAUW + erase,
  // which is exactly what we need here.
  auto E = std::make_unique<jeandle::ReplaceLoadEffect>();
  E->Block = ICmp->getParent();
  E->Target = ICmp;
  E->Replacement = C;
  E->SeqNo = Result.nextSeqNo();
  E->setMutationOwner(BaseID);
  Result.addBlockEffect(std::move(E));
  Aliases.addScalarAlias(ICmp, C);
  return true;
}

// Dispatch a recognized JavaOp on a virtual receiver to its fold. Returns
// true iff the call was handled — folded to a constant / deleted, or a
// known-safe non-escaping shape needing no transform; false routes the call
// to the generic escape path.
bool Analyzer::processJavaOp(CallBase *CB) {
  using namespace jeandle::pea;
  if (isJeandleArrayLength(CB))
    return foldArrayLength(CB);
  if (isJeandleLoadKlass(CB))
    return foldLoadKlass(CB);
  if (isJeandleGetClass(CB))
    return foldGetClass(CB);
  if (isJeandleCheckCast(CB))
    return foldCheckCast(CB);
  if (isJeandleCheckInstanceOf(CB))
    return foldCheckCast(CB);
  if (isJeandleInstanceOf(CB))
    return foldInstanceOf(CB);
  if (isJeandleMonitorEnter(CB))
    return foldMonitorEnter(CB);
  if (isJeandleMonitorExit(CB))
    return foldMonitorExit(CB);
  if (isJeandleArrayStoreCheck(CB))
    return foldArrayStoreCheck(CB);
  if (isJeandlePostBarrier(CB))
    return foldPostBarrier(CB);
  if (isJeandleCheckIfValueBased(CB))
    return foldCheckIfValueBased(CB);
  if (isJeandleRegisterFinalizerIfNeeded(CB))
    return foldRegisterFinalizerIfNeeded(CB);
  return false;
}

void Analyzer::propagatePointerAlias(Instruction *I) {
  // The instruction is a pointer-identity-preserving transformation whose
  // operand carries a virtual alias. Forward the alias to the result.
  if (Aliases.getVirtualAlias(I))
    return;

  // Select aliases are whole-object aliases only when the shared identity
  // resolver proves every defined arm denotes the same object at offset zero.
  // Any derived, undef, external, or differing-object shape is handed to the
  // generic escape path.
  if (auto *Sel = dyn_cast<SelectInst>(I)) {
    auto Identity = jeandle::pea::resolveVirtualIdentity(
        Sel, CurrentState, Aliases, DL,
        jeandle::pea::VirtualIdentityMode::WholeObject);
    if (Identity.isDefined()) {
      Aliases.addVirtualAlias(I, Identity.getObjectID(),
                              /*IsWholeObject=*/true);
      return;
    }
    materializeAllVirtualOperands(I);
    return;
  }

  auto WholeIdentity = jeandle::pea::resolveVirtualIdentity(
      I, CurrentState, Aliases, DL,
      jeandle::pea::VirtualIdentityMode::WholeObject);
  auto BaseID =
      WholeIdentity.isDefined()
          ? std::optional<jeandle::ObjectID>(WholeIdentity.getObjectID())
          : jeandle::pea::resolveVirtualRef(I, CurrentState, Aliases, DL);
  if (!BaseID) {
    // Couldn't resolve — the underlying chain may have already escaped.
    materializeAllVirtualOperands(I);
    return;
  }
  Aliases.addVirtualAlias(I, *BaseID,
                          /*IsWholeObject=*/WholeIdentity.isDefined());
}

// True iff U is a "deopt" operand-bundle input of the call currently
// recorded as handled (HandledDeoptCall) whose operand number the deopt-pool
// rewrite plan accounted for (HandledDeoptOperandNos). Such a reference is
// described frame state, not an escape; escape-driven walks
// (materializeUnhandledDeoptBundleOperands, collectDistinctVirtualOperands)
// skip it.
bool Analyzer::isHandledDeoptBundleOperand(const Use &U, Instruction *I) {
  auto *CB = dyn_cast<CallBase>(I);
  if (!CB || CB != HandledDeoptCall)
    return false;
  unsigned OpIdx = U.getOperandNo();
  if (!CB->isBundleOperand(OpIdx))
    return false;
  if (!CB->getOperandBundleForOperand(OpIdx).isDeoptOperandBundle())
    return false;
  return HandledDeoptOperandNos.contains(OpIdx);
}

// Defined below (near the materialize-placement helpers); forward-declared
// here so recordDeoptBundleMappings can gate on it.
static bool hasDeoptBundle(CallBase *CB);

// Plan and emit the deopt-pool rewrite for one safepoint call. A safepoint's
// still-virtual objects are normally DESCRIBED in the deopt bundle as VO
// descriptors (HotSpot reallocates them on deopt); only the undescribable ones
// are materialized at the safepoint and the pool re-planned. The pipeline:
//   1. Parse/cache the bundle (immutable within one analysis attempt, so the
//      parse is reused across loop-fixpoint revisits).
//   2. Build a DeoptPoolPlannerInput: legacy descriptors and scope roots
//      (locals, stack, monitors) in wire order, plus the current VOs expanded
//      field-by-field with per-element array canonicity checks.
//   3. planDeoptPool. If it returns FallbackSeeds, materialize those VOs at
//      the safepoint and replan (monotonic change => full rebuild per attempt).
//   4. Freeze the final plan as an immutable shared object and emit one atomic
//      whole-pool RewriteDeoptPoolEffect transaction.
//   5. Mark the exact source occurrences the plan rewrote/removed as handled so
//      later escape scans treat them as non-escaping.
void Analyzer::recordDeoptBundleMappings(CallBase *CB) {
  using namespace jeandle::pea;

  HandledDeoptCall = nullptr;
  HandledDeoptOperandNos.clear();
  if (!hasDeoptBundle(CB))
    return;
  auto Deopt = CB->getOperandBundle(LLVMContext::OB_deopt);
  if (!Deopt)
    return;

  // The deopt bundle is immutable within one analysis attempt, so the parse is
  // a pure function of CB; reuse the cached parse across loop-fixpoint
  // revisits.
  std::optional<ParsedDeoptBundle> &Cached = DeoptParseCache[CB];
  if (!Cached) {
    DeoptBundleParseResult ParsedResult = parseDeoptBundle(*CB);
    if (!ParsedResult.Bundle)
      return;
    Cached = std::move(*ParsedResult.Bundle);
  }
  const ParsedDeoptBundle &Parsed = *Cached;

  auto SourceValue = [&](DeoptPoolSemanticCellID Cell) -> Value * {
    if (Cell >= Parsed.OriginalInputs.size())
      return nullptr;
    return Parsed.OriginalInputs[Cell];
  };
  auto IsVirtualHere = [&](jeandle::ObjectID ID) {
    const jeandle::ObjectState *State = CurrentState.getObjectStateOptional(ID);
    return State && State->isVirtual();
  };
  auto IsCurrentVirtual = [&](jeandle::ObjectID ID) {
    return ID < Result.VirtualObjects.size() && Eligible.lookup(ID) &&
           IsVirtualHere(ID);
  };
  auto ResolveCurrentVirtual =
      [&](Value *V) -> std::optional<jeandle::ObjectID> {
    if (!V || !jeandle::isWideOopType(V->getType()))
      return std::nullopt;
    VirtualIdentityResult Identity = resolveVirtualIdentity(
        V, CurrentState, Aliases, DL, VirtualIdentityMode::WholeObject);
    if (!Identity.isDefined() || !IsCurrentVirtual(Identity.getObjectID()))
      return std::nullopt;
    return Identity.getObjectID();
  };
  auto IsDescribableOop = [](Value *V) {
    if (!V || !jeandle::isWideOopType(V->getType()))
      return false;
    Value *Stripped = V->stripPointerCasts();
    return !isa<Constant>(Stripped) || isa<ConstantPointerNull>(Stripped);
  };
  auto IsEncodableOffset = [](int64_t Offset) {
    return Offset >= 0 &&
           static_cast<uint64_t>(Offset) <=
               static_cast<uint64_t>(std::numeric_limits<int32_t>::max());
  };

  // A fallback materialization monotonically changes current object state.
  // Rebuild the entire semantic graph after every such change; no partial
  // planner result is durable.
  for (unsigned Attempt = 0; Attempt <= Result.VirtualObjects.size();
       ++Attempt) {
    DeoptPoolPlannerInput Input;
    SmallVector<DeoptPoolScalarTokenBinding, 32> ScalarBindings;
    SmallVector<DeoptPoolCurrentCellBinding, 8> CurrentCells;
    DenseMap<jeandle::ObjectID, unsigned> CurrentNodeIndices;
    SmallVector<jeandle::ObjectID, 8> CurrentExpansionQueue;
    uint64_t NextScalarToken = 1;

    auto BindScalar = [&](Value *V) {
      uint64_t Token = NextScalarToken++;
      ScalarBindings.push_back({Token, V});
      return Token;
    };

    auto RegisterCurrentNode = [&](jeandle::ObjectID ID) {
      if (CurrentNodeIndices.count(ID))
        return;
      unsigned NodeIndex = Input.CurrentNodes.size();
      CurrentNodeIndices.try_emplace(ID, NodeIndex);
      Input.CurrentNodes.emplace_back();
      CurrentExpansionQueue.push_back(ID);
    };

    auto ExpandCurrentNode = [&](jeandle::ObjectID ID) {
      unsigned NodeIndex = CurrentNodeIndices.lookup(ID);
      CurrentDeoptPoolNode Node;
      Node.ID = ID;
      if (ID >= Result.VirtualObjects.size()) {
        Node.Describable = false;
        Input.CurrentNodes[NodeIndex] = std::move(Node);
        return;
      }

      jeandle::VirtualObject &VObj = *Result.VirtualObjects[ID];
      Node.Klass = VObj.Klass;
      Node.IsArray = VObj.isArray();
      bool HasIdentity = VObj.IsSynthetic ? VObj.SyntheticPhi != nullptr
                                          : VObj.AllocationCall != nullptr;
      Node.Describable = IsCurrentVirtual(ID) && VObj.Klass != 0 && HasIdentity;

      auto AddScalarField = [&](int64_t Offset,
                                jeandle::HotspotBasicType BasicType, Value *V) {
        if (!IsEncodableOffset(Offset) || !V || !isValueAvailableAt(V, CB)) {
          Node.Describable = false;
          return;
        }
        if (BasicType == jeandle::T_INT)
          V = widenDeoptScalar(V, CB);
        Node.Fields.push_back(DeoptPoolFieldInput::scalar(
            InvalidDeoptPoolSemanticCellID, Offset, BasicType, BindScalar(V)));
      };

      auto AddRealOopField = [&](int64_t Offset, Value *V) {
        if (!IsDescribableOop(V)) {
          Node.Describable = false;
          return;
        }
        AddScalarField(Offset, jeandle::T_OBJECT, V);
      };

      auto AddCurrentRefField = [&](int64_t Offset, jeandle::ObjectID Target) {
        if (!IsEncodableOffset(Offset) ||
            Target >= Result.VirtualObjects.size()) {
          Node.Describable = false;
          return;
        }
        if (!IsCurrentVirtual(Target)) {
          AddRealOopField(Offset, realIdentityOf(Target));
          return;
        }
        RegisterCurrentNode(Target);
        Node.Fields.push_back(DeoptPoolFieldInput::reference(
            InvalidDeoptPoolSemanticCellID, Offset,
            DeoptPoolNodeRef::current(Target)));
      };

      auto AddFieldValue = [&](int64_t Offset, const jeandle::FieldValue &FV) {
        if (!IsEncodableOffset(Offset)) {
          Node.Describable = false;
          return;
        }
        if (FV.isVirtualRef()) {
          AddCurrentRefField(Offset, FV.getVirtualRef());
          return;
        }
        if (FV.isMaterializedRef()) {
          AddRealOopField(Offset, FV.getMaterialized());
          return;
        }
        if (!FV.isScalar() || !FV.getDeclaredType()) {
          Node.Describable = false;
          return;
        }

        Value *Scalar = FV.getScalar();
        jeandle::HotspotBasicType BasicType =
            jeandle::LLVM2JavaComputational(FV.getDeclaredType());
        if (BasicType == jeandle::T_OBJECT) {
          if (std::optional<jeandle::ObjectID> Target =
                  ResolveCurrentVirtual(Scalar)) {
            AddCurrentRefField(Offset, *Target);
            return;
          }
          AddRealOopField(Offset, Scalar);
          return;
        }
        if (BasicType == jeandle::T_ILLEGAL ||
            BasicType == jeandle::T_NARROWOOP) {
          Node.Describable = false;
          return;
        }
        AddScalarField(Offset, BasicType, Scalar);
      };

      auto FSIt = FieldStates.find(ID);
      if (VObj.isArray()) {
        if (!VObj.ArrayElementType || VObj.ArrayIndexScale == 0) {
          Node.Describable = false;
          Input.CurrentNodes[NodeIndex] = std::move(Node);
          return;
        }

        // Array canonicity gauntlet: every touched element must map to a
        // whole, in-bounds, correctly-typed cell that HotSpot can reallocate
        // on deopt. A store that straddles elements, lands at a non-canonical
        // offset, uses the wrong element type, or writes a partial byte range
        // makes the array undescribable, which flips Node.Describable to false
        // and forces the planner to treat it as a fallback seed.
        const DenseMap<int64_t, jeandle::FieldValue> *Touched =
            FSIt == FieldStates.end() ? nullptr : &FSIt->second;
        if (Touched) {
          int64_t Base = static_cast<int64_t>(VObj.ArrayBaseOffset);
          int64_t Scale = static_cast<int64_t>(VObj.ArrayIndexScale);
          for (const auto &Entry : *Touched) {
            std::optional<int64_t> Delta = checkedOffsetSub(Entry.first, Base);
            Type *TouchedType = Entry.second.getDeclaredType();
            bool Canonical =
                Delta && *Delta >= 0 && Scale > 0 && *Delta % Scale == 0 &&
                static_cast<uint64_t>(*Delta / Scale) < VObj.ArrayLength &&
                IsEncodableOffset(Entry.first);
            bool ExactElementType =
                TouchedType &&
                (TouchedType == VObj.ArrayElementType ||
                 (VObj.ArrayElementType->isIntegerTy(1) &&
                  TouchedType->isIntegerTy(8) && VObj.ArrayIndexScale == 1));
            bool ExactStoreSize = false;
            bool FullByteRange = false;
            if (TouchedType) {
              TypeSize StoreSize = DL.getTypeStoreSize(TouchedType);
              if (!StoreSize.isScalable()) {
                uint64_t FixedStoreSize = StoreSize.getFixedValue();
                ExactStoreSize = FixedStoreSize == static_cast<uint64_t>(Scale);
                if (Delta && *Delta >= 0 && Scale > 0) {
                  std::optional<uint64_t> ArrayBytes = llvm::checkedMulUnsigned(
                      static_cast<uint64_t>(VObj.ArrayLength),
                      static_cast<uint64_t>(VObj.ArrayIndexScale));
                  uint64_t Start = static_cast<uint64_t>(*Delta);
                  std::optional<uint64_t> End =
                      llvm::checkedAddUnsigned(Start, FixedStoreSize);
                  FullByteRange = ArrayBytes && End && *End <= *ArrayBytes;
                }
              }
            }
            if (!Canonical || !ExactElementType || !ExactStoreSize ||
                !FullByteRange) {
              Node.Describable = false;
              Input.CurrentNodes[NodeIndex] = std::move(Node);
              return;
            }
          }
        }

        Constant *Default = Constant::getNullValue(VObj.ArrayElementType);
        for (uint32_t Index = 0; Index < VObj.ArrayLength; ++Index) {
          std::optional<int64_t> Offset = checkedArrayElementOffset(
              VObj.ArrayBaseOffset, Index, VObj.ArrayIndexScale);
          if (!Offset || !IsEncodableOffset(*Offset)) {
            Node.Describable = false;
            break;
          }
          if (Touched) {
            auto It = Touched->find(*Offset);
            if (It != Touched->end()) {
              AddFieldValue(*Offset, It->second);
              continue;
            }
          }
          jeandle::HotspotBasicType BasicType =
              jeandle::LLVM2JavaComputational(VObj.ArrayElementType);
          if (BasicType == jeandle::T_ILLEGAL ||
              BasicType == jeandle::T_NARROWOOP) {
            Node.Describable = false;
            break;
          }
          AddScalarField(*Offset, BasicType, Default);
        }
      } else if (FSIt != FieldStates.end()) {
        SmallVector<int64_t, 8> Offsets;
        Offsets.reserve(FSIt->second.size());
        for (const auto &Entry : FSIt->second)
          Offsets.push_back(Entry.first);
        llvm::sort(Offsets);
        for (int64_t Offset : Offsets)
          AddFieldValue(Offset, FSIt->second.lookup(Offset));
      }

      Input.CurrentNodes[NodeIndex] = std::move(Node);
    };

    auto AddCurrentOverlay = [&](DeoptPoolSemanticCellID Cell, Value *V) {
      std::optional<jeandle::ObjectID> ID = ResolveCurrentVirtual(V);
      if (!ID)
        return;
      RegisterCurrentNode(*ID);
      Input.Overlays.push_back({Cell, *ID});
      CurrentCells.push_back({Cell, *ID});
    };

    // Legacy descriptors form the durable half of the graph. Only a scalar
    // T_OBJECT field may be reclassified as a current reference; primitive
    // fields remain scalar even when their SSA dependency graph mentions an
    // allocation.
    for (const ParsedDeoptDescriptor &Descriptor : Parsed.Descriptors) {
      LegacyDeoptPoolNode Node;
      Node.WireID = static_cast<uint32_t>(Descriptor.WireID);
      Node.Klass = Descriptor.Klass;
      Node.IsArray = Descriptor.IsArray;
      for (const ParsedDeoptField &Field : Descriptor.Fields) {
        DeoptPoolSemanticCellID Cell = Field.ValueCell.OperandIndex;
        if (Field.TargetWireID) {
          Node.Fields.push_back(DeoptPoolFieldInput::reference(
              Cell, Field.Offset,
              DeoptPoolNodeRef::legacy(
                  static_cast<uint32_t>(*Field.TargetWireID))));
          continue;
        }
        Value *V = SourceValue(Cell);
        Node.Fields.push_back(DeoptPoolFieldInput::scalar(
            Cell, Field.Offset, Field.Encoding.BasicType, BindScalar(V)));
        if (Field.Encoding.BasicType == jeandle::T_OBJECT)
          AddCurrentOverlay(Cell, V);
      }
      Input.LegacyNodes.push_back(std::move(Node));
    }

    auto AddRoot = [&](const DeoptSemanticCell &Cell,
                       jeandle::HotspotBasicType BasicType,
                       std::optional<int32_t> TargetWireID,
                       DeoptPoolRootKind Kind) {
      if (TargetWireID) {
        Input.Roots.push_back(DeoptPoolRootInput::reference(
            Cell.OperandIndex, Kind,
            DeoptPoolNodeRef::legacy(static_cast<uint32_t>(*TargetWireID))));
        return;
      }
      Value *V = SourceValue(Cell.OperandIndex);
      Input.Roots.push_back(
          DeoptPoolRootInput::scalar(Cell.OperandIndex, Kind, BindScalar(V)));
      if (BasicType == jeandle::T_OBJECT)
        AddCurrentOverlay(Cell.OperandIndex, V);
    };

    // Preserve scope wire order: locals, expression stack, then monitors,
    // repeated for every inlined scope.
    for (const ParsedDeoptScope &Scope : Parsed.Scopes) {
      for (const ParsedDeoptScopeValue &Local : Scope.Locals)
        AddRoot(Local.ValueCell, Local.Encoding.BasicType, Local.TargetWireID,
                DeoptPoolRootKind::Local);
      for (const ParsedDeoptScopeValue &Stack : Scope.Stack)
        AddRoot(Stack.ValueCell, Stack.Encoding.BasicType, Stack.TargetWireID,
                DeoptPoolRootKind::Stack);
      for (const ParsedDeoptMonitor &Monitor : Scope.Monitors)
        AddRoot(Monitor.OwnerCell, Monitor.Encoding.BasicType,
                Monitor.OwnerWireID, DeoptPoolRootKind::MonitorOwner);
    }

    // All exact legacy/root overlay seeds are registered before field
    // expansion. Expanding in queue order then appends newly discovered field
    // targets in field semantic order; registration before expansion also
    // makes current-object cycles finite.
    for (unsigned Index = 0; Index < CurrentExpansionQueue.size(); ++Index)
      ExpandCurrentNode(CurrentExpansionQueue[Index]);

    DeoptPoolPlannerResult Planned = planDeoptPool(Input);
    if (Planned.Error)
      return;
    if (!Planned.FallbackSeeds.empty()) {
      bool MadeProgress = false;
      for (CurrentDeoptNodeID CurrentID : Planned.FallbackSeeds) {
        jeandle::ObjectID ID = static_cast<jeandle::ObjectID>(CurrentID);
        if (!IsCurrentVirtual(ID))
          continue;
        materializeAt(ID, CB, MatReason::Unhandled);
        if (!IsCurrentVirtual(ID))
          MadeProgress = true;
      }
      if (!MadeProgress)
        return;
      continue;
    }
    if (!Planned.Plan)
      return;
    if (!Planned.Plan->needsRewrite()) {
      assert(Planned.Plan->currentMembers().empty() &&
             "a current virtual identity must change the deopt pool");
      return;
    }

    PrepareFinalDeoptPoolBundleResult Prepared =
        prepareFinalDeoptPoolBundlePlan(Parsed, *Planned.Plan, ScalarBindings,
                                        CurrentCells);
    if (!Prepared.Plan)
      return;

    auto ImmutablePlan = std::make_shared<const FinalDeoptPoolBundlePlan>(
        std::move(*Prepared.Plan));
    for (CurrentDeoptNodeID CurrentID : ImmutablePlan->graph().currentMembers())
      observeFieldDefinitions(static_cast<jeandle::ObjectID>(CurrentID),
                              FieldDefinitions);

    auto Effect =
        std::make_unique<jeandle::RewriteDeoptPoolEffect>(CB, ImmutablePlan);
    Effect->Block = CB->getParent();
    Effect->SeqNo = Result.nextSeqNo();
    Result.addBlockEffect(std::move(Effect));

    // Only exact source occurrences rewritten to a VORef or removed with a
    // pruned legacy descriptor are non-escaping. Scalar cells merely copied
    // by the complete plan remain ordinary executable uses.
    HandledDeoptCall = CB;
    for (const FinalDeoptPoolCurrentOccurrence &Occurrence :
         ImmutablePlan->currentOccurrences()) {
      if (!Occurrence.SemanticCell)
        continue;
      unsigned Cell = *Occurrence.SemanticCell;
      if (Cell < Deopt->Inputs.size())
        HandledDeoptOperandNos.insert(Deopt->Inputs[Cell].getOperandNo());
    }
    return;
  }
}

void Analyzer::materializeUnhandledDeoptBundleOperands(CallBase *CB) {
  auto Deopt = CB->getOperandBundle(LLVMContext::OB_deopt);
  if (!Deopt)
    return;

  SmallVector<jeandle::ObjectID, 4> ToMaterialize;
  DenseSet<jeandle::ObjectID> Seen;
  for (const Use &U : Deopt->Inputs) {
    if (isHandledDeoptBundleOperand(U, CB))
      continue;
    Value *V = U.get();
    if (!V)
      continue;
    auto ID = jeandle::pea::resolveVirtualRef(V, CurrentState, Aliases, DL);
    if (!ID)
      continue;
    if (Seen.insert(*ID).second)
      ToMaterialize.push_back(*ID);
  }
  llvm::sort(ToMaterialize);
  for (jeandle::ObjectID ID : ToMaterialize)
    materializeAt(ID, CB, MatReason::Unhandled);
}

void Analyzer::collectDistinctVirtualOperands(
    Instruction *I, SmallVectorImpl<jeandle::ObjectID> &Out) {
  // Walk every operand of I, skipping "deopt" operand-bundle inputs that a
  // surviving pool plan already covers: a described deopt-state reference is
  // NOT an escape. Resolve each remaining operand via resolveVirtualRef and
  // collect each distinct virtual ObjectID. Deterministic order is required by
  // the caller (effect emission order), so the output is sorted.
  DenseSet<jeandle::ObjectID> Seen;
  for (Use &U : I->operands()) {
    Value *V = U.get();
    if (!V)
      continue;
    if (isHandledDeoptBundleOperand(U, I))
      continue;
    if (auto MaybeID =
            jeandle::pea::resolveVirtualRef(V, CurrentState, Aliases, DL)) {
      if (Seen.insert(*MaybeID).second)
        Out.push_back(*MaybeID);
    }
  }
  llvm::sort(Out);
}

#ifndef NDEBUG
bool Analyzer::debugReferencesLiveVirtualObject(Value *V) {
  // Backwards BFS over V's pointer-derivation def chain. ever-seen Visited
  // (each value once) bounds the walk to O(distinct values). At each value,
  // an alias-map hit whose ObjectState is still virtual means V transitively
  // denotes a still-virtual VO — the resolve-cap invariant forbids this when
  // resolveVirtualRef(V) failed. A materialized alias is a terminal (a real
  // object), so the walk does not continue past it.
  SmallPtrSet<Value *, 16> Visited;
  SmallVector<Value *, 8> Worklist(1, V);
  while (!Worklist.empty()) {
    Value *Cur = Worklist.pop_back_val();
    if (!Cur || !Visited.insert(Cur).second)
      continue;
    if (auto ID = Aliases.getVirtualAlias(Cur)) {
      if (const jeandle::ObjectState *OS =
              CurrentState.getObjectStateOptional(*ID))
        if (OS->isVirtual())
          return true;
      continue; // materialized or stale alias: terminal, do not walk past.
    }
    if (Aliases.getScalarAlias(Cur) != nullptr)
      continue; // scalar-replaced terminal (folded load etc.), not virtual.
    if (auto *GEP = dyn_cast<GEPOperator>(Cur)) {
      Worklist.push_back(GEP->getPointerOperand());
      continue;
    }
    if (auto *BC = dyn_cast<BitCastOperator>(Cur)) {
      Worklist.push_back(BC->getOperand(0));
      continue;
    }
    if (auto *ASC = dyn_cast<AddrSpaceCastOperator>(Cur)) {
      Worklist.push_back(ASC->getOperand(0));
      continue;
    }
    if (auto *FI = dyn_cast<FreezeInst>(Cur)) {
      Worklist.push_back(FI->getOperand(0));
      continue;
    }
    if (auto *PTI = dyn_cast<PtrToIntInst>(Cur)) {
      Worklist.push_back(PTI->getOperand(0));
      continue;
    }
    if (auto *ITP = dyn_cast<IntToPtrInst>(Cur)) {
      Worklist.push_back(ITP->getOperand(0));
      continue;
    }
    if (auto *PN = dyn_cast<PHINode>(Cur)) {
      for (Value *In : PN->incoming_values())
        Worklist.push_back(In);
      continue;
    }
    if (auto *Sel = dyn_cast<SelectInst>(Cur)) {
      Worklist.push_back(Sel->getTrueValue());
      Worklist.push_back(Sel->getFalseValue());
      continue;
    }
    // Any other opcode (Call, Argument, arithmetic on integers, ...) is opaque
    // to pointer derivation — stop. Arithmetic-on-address cases (tagged
    // pointers via add/or on a ptrtoint) are guarded upstream by the
    // generic-escape materialization at the PtrToInt plus resolve_cap_02.
  }
  return false;
}
#endif

void Analyzer::materializeAllVirtualOperands(Instruction *I) {
  // Trigger materialization for every distinct virtual ObjectID that I uses.
  // After materializeAt, the per-object state in CurrentState flips to
  // Materialized so subsequent resolveVirtualRef queries return nullopt.
  // Ordinary uses already name OrigAlloc, which remains at its original site;
  // a prepared synthetic object is represented by its SyntheticPhi. No
  // per-point allocation or operand-resolution pass is needed.
  SmallVector<jeandle::ObjectID, 4> ToMaterialize;
  collectDistinctVirtualOperands(I, ToMaterialize);
  for (jeandle::ObjectID ID : ToMaterialize)
    materializeAt(ID, I, MatReason::Unhandled);
}

void Analyzer::materializeVirtualCallArgs(CallBase *CB) {
  // Materialize the virtual NON-BUNDLE inputs of the call, unconditionally
  // per argument. Bundle operands are frame state and are handled by
  // recordDeoptBundleMappings, which runs right after this in
  // processInstruction's call dispatch. Running this BEFORE the bundle pass
  // keeps a single identity for an argument that is also a bundle operand
  // across a during-call deopt.
  // A DERIVED argument (GEP/bitcast of the virtual) is materialized the same
  // way: under the reuse-OrigAlloc model the materialized value IS OrigAlloc,
  // which dominates the derived pointer, and the surviving Materialize effect
  // keeps OrigAlloc alive, so the derived argument stays valid.
  SmallVector<jeandle::ObjectID, 4> ArgVOs;
  DenseSet<jeandle::ObjectID> Seen;
  for (Value *Arg : CB->args()) {
    if (!Arg)
      continue;
    auto ID = jeandle::pea::resolveVirtualRef(Arg, CurrentState, Aliases, DL);
    if (!ID)
      continue;
    if (Seen.insert(*ID).second)
      ArgVOs.push_back(*ID);
  }
  llvm::sort(ArgVOs); // deterministic effect order
  for (jeandle::ObjectID ID : ArgVOs)
    materializeAt(ID, CB, MatReason::Unhandled);
}

// Materialize placement is escape-point / predecessor-end: materializeAt
// places at the escape-point instruction; materializeAtPredFromExitInfo places
// at the predecessor's terminator. These positions govern field and lock
// replay, not allocation creation: the receiver is the dominating OrigAlloc or
// SyntheticPhi. Edge-local replay is moved onto the corresponding split edge
// by the transform when the predecessor has other successors.

// Returns true iff CB has at least one "deopt" operand bundle.
static bool hasDeoptBundle(CallBase *CB) {
  for (unsigned i = 0, n = CB->getNumOperandBundles(); i < n; ++i)
    if (CB->getOperandBundleAt(i).getTagName() == "deopt")
      return true;
  return false;
}

// Sweep sibling VOs' FieldStates after a materialisation. Runs for EVERY
// materialisation (outer OR recursive).
void Analyzer::updateOtherStatesForMaterialized(
    jeandle::ObjectID FlippedID, Value *NewPtr,
    DenseMap<jeandle::ObjectID, DenseMap<int64_t, jeandle::FieldValue>> &FS) {
  rewriteVirtualRefsToMaterialized(FlippedID, NewPtr, FS);
}

void Analyzer::bumpMaterializeStat(MatReason R) {
  ++AttemptStats.Materialized;
  switch (R) {
  case MatReason::Unhandled:
    ++AttemptStats.MaterializedUnhandled;
    break;
  case MatReason::Cascade:
    // Cascade and nested still count toward the Unhandled
    // rollup (they are byproducts of an upstream Unhandled escape) but
    // are also bookkept in their own counter for fine-grained audits.
    ++AttemptStats.MaterializedUnhandled;
    ++AttemptStats.MaterializedCascade;
    break;
  case MatReason::Nested:
    ++AttemptStats.MaterializedUnhandled;
    ++AttemptStats.MaterializedNested;
    break;
  case MatReason::Merge:
    ++AttemptStats.MaterializedMerge;
    break;
  case MatReason::LoopExit:
    ++AttemptStats.MaterializedLoopExit;
    break;
  case MatReason::Phi:
    ++AttemptStats.MaterializedPHI;
    break;
  }
}

// Capture the surviving unbalanced monitorenters into a Materialize effect's
// Locks list, for re-emit at the materialize point. Each entry is
// self-contained — Callee + non-receiver args + bytecode depth — because the
// original enter call is removed from IR via ReplaceCall(null), so the
// transform cannot read it back at apply time. Sorted ascending by bytecode
// depth so the re-emitted enters preserve HotSpot lightweight-lock nesting
// order.
static void captureMaterializedLocks(ArrayRef<LockEnter> Stack,
                                     jeandle::MaterializeEffect &E) {
  for (const LockEnter &LE : Stack) {
    CallBase *Enter = LE.Call;
    Function *Callee = Enter ? Enter->getCalledFunction() : nullptr;
    // Guaranteed by ensureMaterialized's pre-capture check: every enter on a
    // captured stack names its callee (an indirect enter cannot be
    // re-emitted, so the VO was kept real instead).
    assert(Callee && "captured lock enter must name a direct callee");
    jeandle::MaterializedLock ML;
    ML.Callee = Callee;
    for (unsigned i = 1, e = Enter->arg_size(); i < e; ++i)
      ML.NonReceiverArgs.push_back(Enter->getArgOperand(i));
    ML.BytecodeDepth = LE.BytecodeDepth;
    E.Locks.push_back(std::move(ML));
  }
  llvm::sort(E.Locks, [](const jeandle::MaterializedLock &A,
                         const jeandle::MaterializedLock &B) {
    return A.BytecodeDepth < B.BytecodeDepth;
  });
}

// Whether Root can be produced at the program point IP: a parented
// instruction must dominate IP; an unparented analyzer-built non-PHI
// instruction (pea.coerce bitcast) is spliced at the use point by the
// transform in postorder — sound iff every leaf of its operand chain is
// available (checked recursively); an unparented analyzer-built PHI shell
// (merge field-PHI / Case-C PHI) is inserted by its CreatePHI effect into
// its PhiHome block — sound iff that home block dominates IP's block;
// Constants / Arguments are always available.  A replay on an invoke's normal
// edge may also use the invoke result: it is unavailable before the terminator
// but defined on that exact edge, where splitReplayEdges places any real replay
// operations. Querying DT.dominates on an unparented instruction directly is
// ill-defined (it is in no domtree node), so it must never reach the raw DT
// query.
bool Analyzer::isValueAvailableAt(Value *Root, Instruction *IP,
                                  BasicBlock *ReplaySource,
                                  BasicBlock *ReplayTarget) {
  SmallPtrSet<Value *, 8> Visited;
  SmallVector<Value *, 8> Worklist(1, Root);
  while (!Worklist.empty()) {
    Value *Cur = Worklist.pop_back_val();
    if (!Cur || !Visited.insert(Cur).second)
      continue;
    auto *I = dyn_cast<Instruction>(Cur);
    if (!I)
      continue; // Constant / Argument: always available.
    if (I->getParent()) {
      if (DT.dominates(I, IP))
        continue;
      auto *Invoke = dyn_cast<InvokeInst>(IP);
      bool AvailableOnNormalEdge =
          ReplaySource && ReplayTarget && IP == ReplaySource->getTerminator() &&
          I == Invoke && Invoke->getNormalDest() == ReplayTarget;
      if (!AvailableOnNormalEdge)
        return false;
      continue;
    }
    if (auto *PN = dyn_cast<PHINode>(I)) {
      auto It = PhiHome.find(PN);
      if (It == PhiHome.end() || (It->second != IP->getParent() &&
                                  !DT.dominates(It->second, IP->getParent())))
        return false;
      continue;
    }
    for (Value *Op : I->operands())
      Worklist.push_back(Op);
  }
  return true;
}

// Read-only preflight over a synthetic VO's identity DAG: returns true iff
// every transitively-referenced source is a materializable synthetic or an
// ordinary leaf with a live OrigAlloc. Visiting guards cycles; Planned caches
// successful sub-DAGs; Leaves collects the ordinary leaf allocations whose
// retention prepareSyntheticDAG will commit.
bool Analyzer::canPrepareSyntheticDAG(jeandle::ObjectID ID,
                                      DenseSet<jeandle::ObjectID> &Visiting,
                                      DenseSet<jeandle::ObjectID> &Planned,
                                      DenseSet<jeandle::ObjectID> &Leaves) {
  if (PreparedSyntheticIDs.count(ID) || Planned.count(ID))
    return true;
  if (ID >= Result.VirtualObjects.size() || !Eligible.lookup(ID))
    return false;
  jeandle::VirtualObject &VObj = *Result.VirtualObjects[ID];
  PHINode *Phi = VObj.SyntheticPhi;
  if (!VObj.IsSynthetic || !Phi || !Phi->getParent() ||
      VObj.SyntheticSourceIDs.size() != Phi->getNumIncomingValues())
    return false;
  if (!Visiting.insert(ID).second)
    return false;

  for (jeandle::ObjectID SourceID : VObj.SyntheticSourceIDs) {
    if (SourceID == jeandle::InvalidObjectID)
      continue;
    if (SourceID >= Result.VirtualObjects.size()) {
      Visiting.erase(ID);
      return false;
    }
    jeandle::VirtualObject &Source = *Result.VirtualObjects[SourceID];
    if (Source.IsSynthetic) {
      if (!canPrepareSyntheticDAG(SourceID, Visiting, Planned, Leaves)) {
        Visiting.erase(ID);
        return false;
      }
      continue;
    }
    if (!Source.AllocationCall) {
      Visiting.erase(ID);
      return false;
    }
    Leaves.insert(SourceID);
  }

  Visiting.erase(ID);
  Planned.insert(ID);
  return true;
}

// Walk a synthetic VO's per-pred sources and observe each live predecessor's
// reaching field definitions, recursing through nested synthetics. Used on the
// ineligibility path so a synthetic that cannot be prepared still restores the
// store liveness of its sources' live incoming edges.
void Analyzer::observeSyntheticSourceDefinitions(
    jeandle::ObjectID ID, DenseSet<jeandle::ObjectID> &Visited) {
  if (!Visited.insert(ID).second)
    return;
  jeandle::VirtualObject &VObj = *Result.VirtualObjects[ID];
  if (!VObj.IsSynthetic || !VObj.SyntheticPhi)
    return;
  BasicBlock *Merge = VObj.SyntheticPhi->getParent();
  for (unsigned I = 0; I < VObj.SyntheticSourceIDs.size(); ++I) {
    jeandle::ObjectID SourceID = VObj.SyntheticSourceIDs[I];
    if (SourceID == jeandle::InvalidObjectID)
      continue;
    BasicBlock *Pred = VObj.SyntheticPhi->getIncomingBlock(I);
    EdgeContribution Contribution = contributionFor(Pred, Merge);
    if (Contribution.isLive())
      observeFieldDefinitions(SourceID, Contribution.Data->FieldDefinitions);
    if (Result.VirtualObjects[SourceID]->IsSynthetic)
      observeSyntheticSourceDefinitions(SourceID, Visited);
  }
}

// Mark every synthetic node in a validated DAG as prepared, recursing through
// nested synthetics before the root. Clearing any prior EscapeClassification
// entry lets the final commit reclassify the synthetic from its surviving
// effects. Committing guards against cycles that the preflight already
// rejected.
void Analyzer::commitPreparedSyntheticDAG(
    jeandle::ObjectID ID, DenseSet<jeandle::ObjectID> &Committing) {
  if (PreparedSyntheticIDs.count(ID))
    return;
  bool Inserted = Committing.insert(ID).second;
  assert(Inserted && "preflight must reject a cyclic synthetic DAG");
  (void)Inserted;

  jeandle::VirtualObject &VObj = *Result.VirtualObjects[ID];
  for (jeandle::ObjectID SourceID : VObj.SyntheticSourceIDs)
    if (SourceID != jeandle::InvalidObjectID &&
        Result.VirtualObjects[SourceID]->IsSynthetic)
      commitPreparedSyntheticDAG(SourceID, Committing);
  PreparedSyntheticIDs.insert(ID);
  Result.EscapeClassification.erase(ID);
  Committing.erase(ID);
}

bool Analyzer::prepareSyntheticDAG(jeandle::ObjectID ID) {
  if (PreparedSyntheticIDs.count(ID))
    return false;
  if (CurrentMode == Mode::StopNewInLoopNest) {
    OverflowFlag = true;
    return false;
  }
  DenseSet<jeandle::ObjectID> Visiting;
  DenseSet<jeandle::ObjectID> Planned;
  DenseSet<jeandle::ObjectID> Leaves;
  if (!canPrepareSyntheticDAG(ID, Visiting, Planned, Leaves)) {
    DenseSet<jeandle::ObjectID> Observed;
    observeSyntheticSourceDefinitions(ID, Observed);
    markIneligible(ID, /*FreshRetry=*/true);
    return false;
  }
  // The read-only preflight above covers the complete DAG. Commit the backing
  // allocation retention only after every synthetic node and ordinary leaf
  // has been validated, so a malformed nested source cannot leave a partial
  // prepare plan.
  for (jeandle::ObjectID Leaf : Leaves)
    KeptSyntheticSourceAllocations.insert(Leaf);

  DenseSet<jeandle::ObjectID> Committing;
  commitPreparedSyntheticDAG(ID, Committing);
  return true;
}

// The shared materialization core, parameterized by MaterializeContext C. Two
// callers drive it: materializeAt (escape-point path, run against the live
// analyzer state) and materializeAtPredFromExitInfo (merge-driven
// per-predecessor path, run against a copied edge state). The context supplies
// the operative state maps, the idempotency set, the recursion target, the
// safe IP, the lock-capture hook, and the state-flip callback, keeping this
// body path-agnostic. The strict-lock cascade materializes shallower-locked
// siblings first so re-emitted monitorenters preserve HotSpot lightweight-lock
// nesting order at the escape point.
void Analyzer::ensureMaterialized(jeandle::ObjectID ID, MaterializeContext &C) {
  assert(ActiveMaterializationPlanID !=
             jeandle::MaterializeEffect::InvalidPlanID &&
         "materialization requires an active final-commit plan");

  // Validate the complete replay snapshot before recursing into nested
  // objects, emitting effects, or mutating virtual/lock state. Source stores
  // may carry any sized first-class type, while replay is atomic-unordered and
  // therefore accepts only the verifier's atomic memory types and widths. An
  // invalid member is still recorded so final commit rejects its entire
  // recursive/lock-cascade transaction.
  if (auto FSIt = C.FieldStates.find(ID); FSIt != C.FieldStates.end())
    for (const auto &KV : FSIt->second) {
      const jeandle::FieldValue &FV = KV.second;
      if (FV.isUnknown())
        continue;
      if (!jeandle::pea::isLegalMaterializationAtomicType(FV.getDeclaredType(),
                                                          DL)) {
        // Preserve every reaching store that analysis tentatively eliminated,
        // including edge-local field definitions.
        observeFieldDefinitions(ID, C.FieldDefinitions);
        MaterializationPlanMembers[ActiveMaterializationPlanID].insert(ID);
        markIneligible(ID, /*FreshRetry=*/true);
        return;
      }
    }

  MaterializationPlanMembers[ActiveMaterializationPlanID].insert(ID);
  if (C.MaterializedSet.count(ID))
    return; // idempotent — first escape wins; also breaks nested-cycles.
  // Reaching definitions must be observed even after a function-wide bail:
  // the virtual marker can survive only to keep pre-bail store liveness
  // point-sensitive across later blocks and reconvergent control flow.
  observeFieldDefinitions(ID, C.FieldDefinitions);
  if (!Eligible.lookup(ID))
    return; // already gave up on this object; nothing to materialize.
  // processBlock publishes a dead exit and returns before walking instructions
  // when no incoming contribution is live. Materialization therefore only
  // runs with a live block state or an edge-local copy of one.

  jeandle::VirtualObject &VObj = *Result.VirtualObjects[ID];

  // Loop-nest overflow guard. When currentMode == StopNewInLoopNest, every
  // virtual object still in scope was created OUTSIDE the active loop nest:
  // processAllocation refuses new virtualizations in that mode. Materializing
  // such an outer-scope object here would force re-iteration of the whole
  // nest (the materialization must propagate back to where the object was
  // allocated), which is exponential in nest depth. So we bail: set
  // OverflowFlag (Jeandle is -fno-exceptions, so a polled flag stands in for
  // throwing) and skip this materialization. The outermost (depth==1)
  // processLoop catches the flag, restores the snapshot, drains the preheader
  // via processStateBeforeLoopOnOverflow, and redoes the nest in
  // Mode::MaterializeAll. No dominance check is needed: in StopNewInLoopNest
  // any virtual object reaching materialization is outer-scope by
  // construction. The ensureVirtualized retryable-bailout branch is
  // intentionally deferred (deopt-adjacent); see TODO in processAllocation.
  if (CurrentMode == Mode::StopNewInLoopNest) {
    OverflowFlag = true;
    return;
  }

  // A Case-C synthetic has no allocation of its own. Prepare its complete
  // identity DAG so every ordinary leaf allocation remains at its original
  // allocation site, then continue through the common point-local field/lock
  // replay path with SyntheticPhi as the receiver.
  if (VObj.IsSynthetic) {
    prepareSyntheticDAG(ID);
    if (!Eligible.lookup(ID) || OverflowFlag)
      return;
  }

  // Cycle prevention: insert BEFORE recursing on any nested VirtualRef
  // ("flip the state then recurse") so a self-referential / cyclic field graph
  // (A.f = B, B.g = A) terminates. The strict-lock cascade below relies on this
  // too.
  C.MaterializedSet.insert(ID);

  // Recursive prerequisite materialization: for each field holding a
  // VirtualRef to an inner virtual, materialize the inner first, then rewrite
  // the outer's FieldStates entry to a MaterializedRef at the inner's real
  // identity. Ordinary inner objects use OrigAlloc; prepared Case-C inner
  // objects use SyntheticPhi. Both identities dominate the replay point, as
  // checked below.
  {
    auto FSIt = C.FieldStates.find(ID);
    if (FSIt != C.FieldStates.end()) {
      SmallVector<int64_t, 4> NestedOffsets;
      for (auto &Kv : FSIt->second)
        if (Kv.second.isVirtualRef())
          NestedOffsets.push_back(Kv.first);
      llvm::sort(NestedOffsets); // determinism
      for (int64_t Off : NestedOffsets) {
        // Re-lookup each iteration; the recursion may have mutated
        // FieldStates (updateStatesForMaterialized below) and invalidated
        // iterators.
        auto It2 = C.FieldStates.find(ID);
        if (It2 == C.FieldStates.end())
          break;
        auto OffIt = It2->second.find(Off);
        if (OffIt == It2->second.end() || !OffIt->second.isVirtualRef())
          continue;
        jeandle::ObjectID InnerID = OffIt->second.getVirtualRef();
        C.Recurse(InnerID, MatReason::Nested);
        // Record the inner's materialized (or kept-real) value for
        // field-replay. When the inner can no longer be materialized as a
        // virtual (a synthetic Case-C VO, or an object that hit an
        // availability bail of its own), its real value survives in IR —
        // the original allocation, or the Case-C merge PHI for a synthetic —
        // and the outer replays that pointer into the field instead of
        // giving up on the outer too. An entry whose object is already
        // materialized contributes its materialized value. The value
        // dominates the materialize point (OrigAlloc dominates every escape
        // point; a Case-C PHI dominates every block that inherited a
        // reference to it) — verified by the availability gate below.
        Value *InnerVal = realIdentityOf(InnerID);
        C.FieldStates[ID][Off] = jeandle::FieldValue::materializedRef(InnerVal);
        // updateStatesForMaterialized: every other still-tracked object whose
        // FieldStates references InnerID must also flip to MaterializedRef.
        updateOtherStatesForMaterialized(InnerID, InnerVal, C.FieldStates);
      }
    }
  }

  // Safe materialization insertion point (path-specific).
  Instruction *SafeIP = C.ComputeSafeIP();
  assert(SafeIP && "materialization requires a safe insertion point");

  // The real replay receiver must itself be available at the semantic replay
  // point. OrigAlloc normally satisfies this by dominance. An allocation
  // invoke result is instead defined on its normal edge; edge-local replay is
  // placed there by the transform. A synthetic receiver can be a cached or
  // loop-carried PHI, so validate every shape explicitly before mutating any
  // lock state.
  Value *ReplayReceiver = realIdentityOf(ID);
  if (!isValueAvailableAt(ReplayReceiver, SafeIP, C.ReplaySource,
                          C.ReplayTarget)) {
    LLVM_DEBUG(dbgs() << "PEA: keep-real receiver unavailable VO=" << ID
                      << " at " << *SafeIP << "\n");
    markIneligible(ID, /*FreshRetry=*/true);
    return;
  }

  // Per-field availability gate: after VirtualRef rewriting, every Scalar /
  // MaterializedRef field value must be available at the same semantic replay
  // point (a snapshot value that does not exist there would replay as a
  // dangling reference).
  auto FSIt = C.FieldStates.find(ID);
  if (FSIt != C.FieldStates.end()) {
    for (auto &Kv : FSIt->second) {
      const jeandle::FieldValue &FV = Kv.second;
      Value *V = nullptr;
      if (FV.isScalar())
        V = FV.getScalar();
      else if (FV.isMaterializedRef())
        V = FV.getMaterialized();
      else
        continue;
      if (!V)
        continue;
      if (!isValueAvailableAt(V, SafeIP, C.ReplaySource, C.ReplayTarget)) {
        LLVM_DEBUG(dbgs() << "PEA: keep-real field unavailable VO=" << ID
                          << " value=" << *V << " at " << *SafeIP << "\n");
        markIneligible(ID, /*FreshRetry=*/true);
        return;
      }
    }
  }

  // From here on NOTHING may abort. The steps below mutate lock state —
  // first the sibling cascade materializes other VOs (capturing and clearing
  // their locks), then this VO's own lock capture clears its operative lock
  // state. An abort after those mutations would leave siblings re-emitting
  // shallower locks at the escape point while this VO's original enter
  // revives at its original (earlier) position — an inverted runtime lock
  // order, exactly what the cascade exists to prevent. This is also why the
  // lock cascade runs AFTER the entry-prerequisite recursion and the
  // availability gate: inner objects must already be materialized (so their
  // re-emitted enters nest inside the outer's) before any outer lock state
  // is cleared.
  auto LCIt = C.LockCounts.find(ID);
  bool HasLiveLocks = (LCIt != C.LockCounts.end() && LCIt->second != 0);
  SmallVector<LockEnter, 4> LocksToReEmit;
  // An enter with no direct callee cannot be re-emitted at the
  // materialize point — keep the whole VO real instead of silently
  // dropping the lock (which would unbalance it against the surviving
  // exit). Checked before any lock state is mutated.
  if (HasLiveLocks)
    if (const auto &Stack = C.LiveLockEnters.lookup(ID); !Stack.empty())
      for (const LockEnter &LE : Stack)
        if (!LE.Call || !LE.Call->getCalledFunction()) {
          markIneligible(ID, /*FreshRetry=*/true);
          return;
        }

  // Strict-lock-order cascade: when this VO has live locks and the runtime
  // requires strict nesting, materialize every other still-locked virtual
  // whose OUTERMOST live lock was acquired strictly before this VO's
  // INNERMOST live lock. LiveLockEnters[id].front() is the min-depth
  // (outermost) lock, .back() is the max-depth (innermost).
  if (HasLiveLocks && StrictLockOrder) {
    const auto &ThisStack = C.LiveLockEnters.lookup(ID);
    assert(!ThisStack.empty() &&
           "LockCount > 0 implies a non-empty LiveLockEnters stack");
    uint32_t ThisMaxDepth = ThisStack.back().BytecodeDepth;
    SmallVector<jeandle::ObjectID, 4> Cascade;
    for (auto &Kv : C.LiveLockEnters) {
      if (Kv.first == ID || Kv.second.empty())
        continue;
      if (C.MaterializedSet.count(Kv.first))
        continue;
      if (Kv.second.front().BytecodeDepth < ThisMaxDepth)
        Cascade.push_back(Kv.first);
    }
    llvm::sort(Cascade); // deterministic order
    for (jeandle::ObjectID OtherID : Cascade)
      C.Recurse(OtherID, MatReason::Cascade);
  }

  // The surviving unbalanced monitorenters on the live stack are captured
  // into the Materialize effect's Locks list for re-emit at the materialize
  // point (captureMaterializedLocks, invoked in the effect-build section
  // below), and the operative lock state is cleared so commit()'s
  // LockCounts!=0 gate does not disqualify. The original enter calls stay
  // removed (their ReplaceCall(null) effects survive); applyMaterialize emits
  // fresh enters at the materialize point. ID's own stack is looked up fresh
  // AFTER the cascade: the cascade's sibling materializations erase their own
  // LiveLockEnters entries, which can rehash the map and invalidate any
  // earlier iterator (never ID's own entry — the cascade skips IDs already
  // in MaterializedSet).
  if (HasLiveLocks) {
    if (const auto &Stack = C.LiveLockEnters.lookup(ID); !Stack.empty()) {
      LocksToReEmit.assign(Stack.begin(), Stack.end());
      C.ClearLockState(ID);
    }
  }

  // Build the Materialize effect (common fields + the per-offset field
  // snapshot), let the context add the path-specific flags, then commit.
  auto E = std::make_unique<jeandle::MaterializeEffect>();
  E->Block = SafeIP->getParent();
  E->SeqNo = Result.nextSeqNo();
  E->InsertBefore = SafeIP;
  E->Target = ReplayReceiver;
  E->setMutationOwner(ID);
  E->LogicalEscape = C.LogicalEscape;
  E->ReplaySource = C.ReplaySource;
  E->ReplayTarget = C.ReplayTarget;
  E->PlanID = ActiveMaterializationPlanID;
  if (FSIt != C.FieldStates.end()) {
    SmallVector<int64_t, 8> Offsets;
    Offsets.reserve(FSIt->second.size());
    for (auto &Kv : FSIt->second)
      Offsets.push_back(Kv.first);
    llvm::sort(Offsets); // deterministic snapshot order
    for (int64_t Off : Offsets) {
      const jeandle::FieldValue &FV = FSIt->second.lookup(Off);
      if (FV.isUnknown())
        continue;
      E->FieldEntries.push_back({Off, FV});
    }
  }
  // Capture the surviving unbalanced enters (sorted ascending by depth) into
  // E->Locks for re-emit at the materialize point by applyMaterialize.
  C.CaptureLocksIntoEffect(LocksToReEmit, ID, *E);
  Result.addBlockEffect(std::move(E));
  bumpMaterializeStat(C.Reason);

  // Flip the per-object state to materialized on this path.
  C.FlipState(ID);

  // Sweep sibling VOs whose FieldStates still hold a VirtualRef to this just
  // materialized object, so a later store/load through a sibling field observes
  // the materialized pointer.
  updateOtherStatesForMaterialized(ID, ReplayReceiver, C.FieldStates);
}

// Escape-point materialization entry point: open a final-commit plan (if this
// is the outermost call), drive the shared core through ensureMaterialized
// against the live analyzer state, and close the plan on exit. Each
// outermost materializeAt establishes one MaterializationPlanID so a recursive
// / strict-lock-cascade transaction can be accepted or rejected atomically at
// commit.
void Analyzer::materializeAt(jeandle::ObjectID ID, Instruction *InsertBefore,
                             MatReason Reason) {
  const bool IsPlanRoot =
      ActiveMaterializationPlanID == jeandle::MaterializeEffect::InvalidPlanID;
  if (IsPlanRoot)
    ActiveMaterializationPlanID = NextMaterializationPlanID++;
  auto FinishPlan = llvm::make_scope_exit([&] {
    if (IsPlanRoot)
      ActiveMaterializationPlanID = jeandle::MaterializeEffect::InvalidPlanID;
  });

  // Escape-point (live-state) path. Delegates the shared cascade, lock-capture,
  // recursive-prereq, dominance, emit, and flip algorithm to
  // ensureMaterialized. This wrapper supplies the live analyzer maps, the
  // function-wide Materialized idempotency set, recursion back into
  // materializeAt, and the live-path specifics: SafeIP is the escape-point
  // instruction, there are no per-predecessor flags, the deopt bundle is
  // sourced from the escape-point call, and the state flip is applied to the
  // live CurrentState.
  auto ClearLockState = [&](jeandle::ObjectID Oid) {
    LockCounts[Oid] = 0;
    LiveLockEnters.erase(Oid);
    if (CurrentState.hasObjectState(Oid)) {
      jeandle::ObjectState &OS =
          CurrentState.getObjectStateForModification(Oid);
      if (OS.isVirtual())
        OS.clearLocks();
    }
  };
  auto ComputeSafeIP = [&]() -> Instruction * {
    // Escape-point placement: always replay at the instruction that triggered
    // the escape.
    //
    // Loop-body escape — the escape point sits in a loop that does not contain
    // the allocation — does not require moving the replay point. The loop
    // fixpoint (processLoop) clears every loop-block effect on each retry
    // (restoreLoopSnapshot), and the post-body mergeStates(Header) records one
    // preheader replay (materializePredsAndMerge ->
    // materializeAtPredFromExitInfo, SafeIP = PH->getTerminator()). OrigAlloc
    // is the stable materialized value. Concretely:
    //   * Escape FLOWS TO THE LATCH (escape block is a loop block): the Iter-0
    //     escape-point Materialize is cleared on Iter 1; the header merge flips
    //     the object to materialized{OrigAlloc}, so the body escape becomes a
    //     no-op (resolveVirtualRef returns nullopt for a materialized object).
    //   * Escape EXITS THE LOOP (escape block is not in the loop): the latch
    //     sees the object virtual, the header merge keeps it virtual
    //     (mergeFieldStates), and the escape-point Materialize persists only on
    //     the escape-exiting path — executed at most once because that path
    //     leaves the loop. The object stays scalar-replaced on the normal path:
    //     true partial escape.
    // Nested loops are handled by recursive processLoop: the outer fixpoint
    // clears the inner-preheader replay and propagates materialized{OrigAlloc}
    // into the inner loop, leaving one replay at the outermost preheader.
    // Mode::StopNewInLoopNest + MaterializeAll escalation remain the safety
    // net for pathological nests.
    //
    // Uses outside the escape-point replay block — notably at a multi-pred
    // merge where the object is still virtual on another arm — remain
    // SSA-sound because OrigAlloc dominates every such use by PEA's invariant
    // (see applyMaterialize, which asserts the receiver equals
    // VObj.AllocationCall; see also the "Materialization model" paragraph in
    // the PartialEscapeTransform.cpp file header).
    return InsertBefore;
  };
  auto FlipState = [&](jeandle::ObjectID Oid) {
    CurrentState.getObjectStateForModification(Oid).escape(realIdentityOf(Oid));
  };

  auto Recurse = [&](jeandle::ObjectID Oid, MatReason R) {
    materializeAt(Oid, InsertBefore, R);
  };
  auto CaptureLocksIntoEffect = [](ArrayRef<LockEnter> Stack, jeandle::ObjectID,
                                   jeandle::MaterializeEffect &E) {
    captureMaterializedLocks(Stack, E);
  };
  // NOTE: every callback is a named local (not a temporary in the aggregate
  // init) so each outlives C — function_ref does NOT own its callable, and a
  // temporary would be destroyed at the end of the `C{...};` statement, leaving
  // a dangling ref for the ensureMaterialized call on the next line.
  MaterializeContext C{FieldStates,    FieldDefinitions,
                       LockCounts,     LiveLockEnters,
                       Materialized,   Reason,
                       InsertBefore,   InsertBefore->getParent(),
                       nullptr,        Recurse,
                       ClearLockState, CaptureLocksIntoEffect,
                       ComputeSafeIP,  FlipState};
  ensureMaterialized(ID, C);
}

bool Analyzer::effectSurvivesIneligibleOwner(const jeandle::Effect &E) const {
  const auto *SE = dyn_cast<jeandle::EliminateStoreEffect>(&E);
  auto *SI = SE ? dyn_cast_or_null<StoreInst>(SE->getTarget()) : nullptr;
  return SI && !ObservedFieldStores.count(SI);
}

void Analyzer::ensureEffectsByOwnerCache() {
  if (EffectsByOwnerCacheEpoch == Result.EffectEpoch)
    return;
  EffectsByOwnerCache.clear();
  for (const auto &Kv : Result.BlockEffects)
    for (const auto &E : Kv.second)
      if (E.hasMutationOwner())
        EffectsByOwnerCache[E.getMutationOwner()].push_back(&E);
  EffectsByOwnerCacheEpoch = Result.EffectEpoch;
}

void Analyzer::dropEffectsForIneligible(
    const DenseSet<jeandle::ObjectID> &IDs) {
  if (IDs.empty())
    return;
  // One pass over BlockEffects drops every effect owned by an ineligible VO
  // (unless it must survive), accounting the allocation-elimination deltas per
  // distinct owner. Replaces a per-VO full scan with a single scan.
  SmallDenseSet<jeandle::ObjectID, 8> DroppedAllocOwners;
  for (auto &Kv : Result.BlockEffects) {
    Kv.second.eraseIf([&](const jeandle::Effect &E) {
      if (!E.hasMutationOwner() || !IDs.count(E.getMutationOwner()))
        return false;
      if (effectSurvivesIneligibleOwner(E))
        return false;
      if (isa<jeandle::EliminateAllocationEffect>(E))
        DroppedAllocOwners.insert(E.getMutationOwner());
      return true;
    });
  }
  if (!DroppedAllocOwners.empty()) {
    Result.VirtualizationDelta -= static_cast<int>(DroppedAllocOwners.size());
    Result.AllocationDelta += static_cast<int>(DroppedAllocOwners.size());
  }
  for (jeandle::ObjectID ID : IDs)
    Result.EscapeClassification[ID] =
        jeandle::PEAResult::EscapeKind::AlwaysEscapes;
  ++Result.EffectEpoch;
}

void Analyzer::commit() {
  // Phase order:
  //   1. Function-exit lock sweep: mark a VO ineligible when its monitor lock
  //      count is nonzero at a real return/resume (unbalanced enter/exit).
  //   2. Unified ineligibility fixpoint: iterate plan rejection (a recursive
  //      / strict-lock-cascade transaction is rejected wholesale if any member
  //      went ineligible), the surviving-use audit for proposed-deletion
  //      allocations, the synthetic-source and live-VirtualRef cascades, and
  //      the field/token availability sweep, until the eligibility set is
  //      stable. Deopt pools are NOT part of this owner fixpoint: each pool is
  //      an atomic safepoint transaction with no mutation owner, and a
  //      late-invalid member/token marks the complete pool invalid.
  //   3. dropEffectsForIneligible: remove every effect owned by an ineligible
  //      VO (except keep-real survivors) and stamp AlwaysEscapes.
  //   4. Escape classification: NeverEscapes / PartiallyEscapes /
  //      AlwaysEscapes for each VO (synthetic-DAG members stay
  //      PartiallyEscapes).
  //   5. Case-B PHI erasure scheduling: NeverEscapes VOs schedule their
  //      aliased PHIs for explicit erasure in the cfg-kill hook.
  //   6. Stats.
  //
  // Any virtual whose monitor lock count is non-zero at a FUNCTION EXIT
  // (a return, or a resume that unwinds out of the method) has unbalanced
  // enter/exit pairs: its elided monitorenter would be dropped without a
  // matching exit, changing the runtime's unbalanced-monitor behavior (a
  // real run throws IllegalMonitorStateException at the return). Keep those
  // objects real; the per-object loop below drops their effects.
  //
  // The check reads the per-block EXIT SNAPSHOTS (BlockExits), not the
  // analyzer's live LockCounts map: the live map only reflects the last
  // processed block, so an unbalanced enter on any other path would slip
  // through. A lock held across the middle of the function (nonzero count at
  // a non-exit block) is fine — it is balanced by a later exit or captured
  // for re-emit at an escape point.
  //
  // A return reached via a deoptimize call is NOT a real function exit:
  // execution continues in the interpreter with the frame state — including
  // any eliminated lock — reconstructed from the deopt bundle (a locked VO
  // is either described there or already materialized, so its count is
  // legitimately nonzero here).
  for (auto &Kv : BlockExits) {
    Instruction *Term = Kv.first->getTerminator();
    if (!isa<ReturnInst>(Term) && !isa<ResumeInst>(Term))
      continue;
    if (isDeoptContinuation(Kv.first))
      continue;
    for (auto &LC : Kv.second.LockCounts)
      if (LC.second != 0) {
        observeFieldDefinitions(LC.first, Kv.second.FieldDefinitions);
        markIneligible(LC.first);
      }
  }

  // -------------------------------------------------------------------------
  // Unified ordinary-effect ineligibility fixpoint, iterated until the set is
  // stable. Two producers:
  //
  //  (a) Transitive ineligibility cascade over LIVE reaching VirtualRef store
  //      definitions plus the synthetic-Case-C source cascade. A definition
  //      becomes live when a load, materialization, deopt snapshot, or
  //      conservative fallback observes it. If its outer is kept real, the
  //      referenced inner must also be real; otherwise the restored store
  //      would write an OrigAlloc that the cfg-kill phase RAUWs to poison. A
  //      definition overwritten before every observation is absent from this
  //      relation and its EliminateStore effect survives outer fallback. This
  //      point-sensitive liveness is what makes the deferred analysis/transform
  //      split sound: a store kept dead in the analysis cannot reach the
  //      transform's restore path.
  //
  //  (b) Field-value availability sweep. Every value
  //      referenced by a surviving effect's field snapshot must be
  //      PRODUCIBLE at apply time: a Constant / Argument / in-IR instruction
  //      (a WeakTrackingVH follows any RAUW), or an unparented analyzer-built
  //      instruction whose operand chain bottoms out at producible values
  //      (the transform splices it at the use point), or an unparented PHI
  //      shell whose owning CreatePHI effect survives (the effect inserts it
  //      at apply). An unparented PHI whose producer VO became ineligible
  //      (its CreatePHI is dropped below) will never exist — any VO whose
  //      surviving Materialize / field-CreatePHI effects reference it is kept
  //      real too. Dropping one VO can orphan more PHIs, hence the fixpoint.
  //
  // Deopt pools are not part of this owner fixpoint. Each pool is an atomic
  // safepoint transaction with no mutation owner. A late-invalid member or
  // output token marks the complete pool invalid for the final retry audit;
  // the pool effect is never edited or removed per virtual object.
  // -------------------------------------------------------------------------
  auto IsAvailableValue = [&](Value *V,
                              const DenseSet<Value *> &OwnedPhis) -> bool {
    SmallPtrSet<Value *, 8> Visited;
    SmallVector<Value *, 8> Worklist(1, V);
    while (!Worklist.empty()) {
      Value *Cur = Worklist.pop_back_val();
      if (!Cur || !Visited.insert(Cur).second)
        continue;
      auto *I = dyn_cast<Instruction>(Cur);
      if (!I)
        continue; // Constant / Argument: always producible.
      if (I->getParent())
        continue; // In IR (a WeakTrackingVH follows any RAUW at apply).
      if (auto *PN = dyn_cast<PHINode>(I)) {
        if (OwnedPhis.contains(PN))
          continue; // Inserted at apply by its surviving CreatePHI.
        return false;
      }
      for (Value *Op : I->operands())
        Worklist.push_back(Op);
    }
    return true;
  };
  auto FieldValuesAvailable = [&](jeandle::ObjectID ID,
                                  const DenseSet<Value *> &OwnedPhis) -> bool {
    ensureEffectsByOwnerCache();
    auto OwnerIt = EffectsByOwnerCache.find(ID);
    if (OwnerIt != EffectsByOwnerCache.end())
      for (const jeandle::Effect *E : OwnerIt->second) {
        if (const auto *ME = dyn_cast<jeandle::MaterializeEffect>(E)) {
          for (const auto &FE : ME->FieldEntries) {
            if (FE.Value.isScalar() &&
                !IsAvailableValue(FE.Value.getScalar(), OwnedPhis))
              return false;
            if (FE.Value.isMaterializedRef() &&
                !IsAvailableValue(FE.Value.getMaterialized(), OwnedPhis))
              return false;
          }
        } else if (const auto *PE = dyn_cast<jeandle::CreatePHIEffect>(E)) {
          // Field-value PHI (the only remaining CreatePHI variant): every
          // incoming must be producible at apply time.
          for (const WeakTrackingVH &In : PE->PHIIncomingValues)
            if (!IsAvailableValue(In, OwnedPhis))
              return false;
        }
      }
    return true;
  };
  auto PoolTokensAvailable = [&](const jeandle::RewriteDeoptPoolEffect &Pool,
                                 const DenseSet<Value *> &OwnedPhis) {
    for (const jeandle::pea::FinalDeoptPoolBundleToken &Token :
         Pool.getPlan().tokens()) {
      if (Token.kind() !=
          jeandle::pea::FinalDeoptPoolBundleTokenKind::TrackedValue)
        continue;
      Value *Tracked = Token.trackedValue();
      if (!Tracked || !IsAvailableValue(Tracked, OwnedPhis))
        return false;
    }
    return true;
  };
  auto ComputeLivePreparedSyntheticClosure =
      [&](const DenseSet<jeandle::ObjectID> &MaterializedIDs,
          DenseSet<jeandle::ObjectID> &LiveSyntheticIDs,
          DenseSet<jeandle::ObjectID> &LiveOrdinaryLeaves) {
        SmallVector<jeandle::ObjectID, 8> Worklist;
        for (jeandle::ObjectID ID : MaterializedIDs) {
          jeandle::VirtualObject &VObj = *Result.VirtualObjects[ID];
          if (VObj.IsSynthetic && PreparedSyntheticIDs.count(ID))
            Worklist.push_back(ID);
        }
        while (!Worklist.empty()) {
          jeandle::ObjectID ID = Worklist.pop_back_val();
          if (!LiveSyntheticIDs.insert(ID).second)
            continue;
          jeandle::VirtualObject &VObj = *Result.VirtualObjects[ID];
          assert(VObj.IsSynthetic && PreparedSyntheticIDs.count(ID) &&
                 "live synthetic materialization requires a prepared identity "
                 "DAG");
          for (jeandle::ObjectID SourceID : VObj.SyntheticSourceIDs) {
            if (SourceID == jeandle::InvalidObjectID)
              continue;
            jeandle::VirtualObject &Source = *Result.VirtualObjects[SourceID];
            if (Source.IsSynthetic) {
              assert(PreparedSyntheticIDs.count(SourceID) &&
                     "prepared synthetic DAG must be transitively complete");
              Worklist.push_back(SourceID);
            } else {
              assert(KeptSyntheticSourceAllocations.count(SourceID) &&
                     "prepared synthetic DAG must retain every ordinary leaf");
              LiveOrdinaryLeaves.insert(SourceID);
            }
          }
        }
      };
  {
    DenseMap<jeandle::ObjectID, SmallDenseSet<jeandle::ObjectID>>
        LiveVirtualRefDeps;
    DenseSet<uint32_t> SurvivingMaterializationPlans;
    DenseMap<CallBase *, const jeandle::RewriteDeoptPoolEffect *> PoolsAt;
    DenseSet<CallBase *> DuplicatePools;
    for (const auto &Kv : Result.BlockEffects)
      for (const auto &E : Kv.second)
        if (const auto *ME = dyn_cast<jeandle::MaterializeEffect>(&E)) {
          assert(ME->PlanID != jeandle::MaterializeEffect::InvalidPlanID &&
                 "materialize effect must belong to a commit plan");
          SurvivingMaterializationPlans.insert(ME->PlanID);
        } else if (const auto *SE = dyn_cast<jeandle::EliminateStoreEffect>(&E))
          if (auto *SI = dyn_cast_or_null<StoreInst>(SE->getTarget()))
            if (ObservedFieldStores.count(SI))
              if (auto RIt = VirtualRefStoreTargets.find(SI);
                  RIt != VirtualRefStoreTargets.end())
                if (E.hasMutationOwner())
                  LiveVirtualRefDeps[E.getMutationOwner()].insert(RIt->second);
    for (const auto &Kv : Result.BlockEffects)
      for (const auto &E : Kv.second)
        if (const auto *Pool = dyn_cast<jeandle::RewriteDeoptPoolEffect>(&E)) {
          CallBase *Safepoint = dyn_cast_or_null<CallBase>(Pool->getTarget());
          if (!Safepoint)
            continue;
          if (!PoolsAt.try_emplace(Safepoint, Pool).second)
            DuplicatePools.insert(Safepoint);
        }
    LateInvalidDeoptPools.clear();
    LateInvalidDeoptPools.insert(DuplicatePools.begin(), DuplicatePools.end());

    bool AnyChange = true;
    while (AnyChange) {
      AnyChange = false;
      // A recursive/nested or strict-lock materialization is one final-commit
      // transaction. If any attempted member became ineligible after effects
      // were recorded, reject every member before the transform can apply a
      // partial replay plan.
      for (uint32_t PlanID : SurvivingMaterializationPlans) {
        auto PIt = MaterializationPlanMembers.find(PlanID);
        assert(PIt != MaterializationPlanMembers.end() &&
               "surviving materialization plan must retain its members");
        bool RejectPlan = llvm::any_of(PIt->second, [&](jeandle::ObjectID ID) {
          return !Eligible.lookup(ID);
        });
        if (!RejectPlan)
          continue;
        for (jeandle::ObjectID ID : PIt->second)
          if (Eligible.lookup(ID)) {
            Eligible[ID] = false;
            AnyChange = true;
          }
      }
      // An ordinary allocation that is neither directly materialized nor
      // retained by a live prepared synthetic DAG is proposed for deletion.
      // Audit its final SSA uses through transparent pointer carriers: every
      // semantic consumer must itself be removed by an eligible effect, or be
      // a deopt operand rewritten by this object's surviving descriptor. This
      // catches future PHI incomings in cyclic RPO regions that were unresolved
      // when their block was processed.
      DenseSet<Instruction *> RemovedTargets;
      DenseSet<jeandle::ObjectID> HasMaterialize;
      for (const auto &Kv : Result.BlockEffects)
        for (const jeandle::Effect &E : Kv.second) {
          if (!E.hasMutationOwner())
            continue;
          bool OwnerEligible = Eligible.lookup(E.getMutationOwner());
          if (OwnerEligible && isa<jeandle::MaterializeEffect>(E))
            HasMaterialize.insert(E.getMutationOwner());
          bool Survives = OwnerEligible || effectSurvivesIneligibleOwner(E);
          if (Survives && (isa<jeandle::ReplaceLoadEffect>(E) ||
                           isa<jeandle::ReplaceCallEffect>(E) ||
                           isa<jeandle::EliminateStoreEffect>(E)))
            if (Instruction *Target = E.getTarget())
              RemovedTargets.insert(Target);
        }
      DenseSet<jeandle::ObjectID> LivePreparedSyntheticIDs;
      DenseSet<jeandle::ObjectID> LiveKeptSyntheticSourceAllocations;
      ComputeLivePreparedSyntheticClosure(HasMaterialize,
                                          LivePreparedSyntheticIDs,
                                          LiveKeptSyntheticSourceAllocations);
      for (const auto &VObjUP : Result.VirtualObjects) {
        jeandle::ObjectID ID = VObjUP->getID();
        if (!Eligible.lookup(ID) || VObjUP->IsSynthetic ||
            HasMaterialize.count(ID) ||
            LiveKeptSyntheticSourceAllocations.count(ID))
          continue;
        Value *Allocation = VObjUP->AllocationCall;
        bool HasSurvivingUse = jeandle::pea::hasUnremovedSemanticUses(
            Allocation, [&](const Use &U) {
              auto *UserI = dyn_cast<Instruction>(U.getUser());
              if (UserI) {
                auto ExitIt = BlockExits.find(UserI->getParent());
                if (ExitIt != BlockExits.end() && ExitIt->second.IsDead)
                  return true;
              }
              if (UserI && RemovedTargets.count(UserI))
                return true;
              auto *CB = dyn_cast_or_null<CallBase>(UserI);
              if (!CB)
                return false;
              if (!CB->isBundleOperand(U.getOperandNo()))
                return jeandle::pea::isPEAHandledNonEscapingIntrinsic(
                    dyn_cast<IntrinsicInst>(CB));
              OperandBundleUse Bundle =
                  CB->getOperandBundleForOperand(U.getOperandNo());
              if (!Bundle.isDeoptOperandBundle())
                return jeandle::pea::isPEAHandledNonEscapingIntrinsic(
                    dyn_cast<IntrinsicInst>(CB));
              if (DuplicatePools.count(CB))
                return false;
              auto PoolIt = PoolsAt.find(CB);
              if (PoolIt == PoolsAt.end())
                return false;
              unsigned SemanticCell = 0;
              bool FoundCell = false;
              for (const Use &BundleInput : Bundle.Inputs) {
                if (BundleInput.getOperandNo() == U.getOperandNo()) {
                  FoundCell = true;
                  break;
                }
                ++SemanticCell;
              }
              if (FoundCell) {
                const auto &Plan = PoolIt->second->getPlan();
                for (jeandle::pea::CurrentDeoptNodeID CurrentID :
                     Plan.graph().currentMembers())
                  if (PoolIt->second->coversExactOccurrence(SemanticCell,
                                                            CurrentID) &&
                      Result.currentIdentityRepresentsSource(CurrentID, ID))
                    return true;
                // A current occurrence in an unreachable legacy descriptor is
                // removed rather than emitted as a final current member. Its
                // exact source use is nevertheless eliminated by the atomic
                // pool rewrite.
                for (const auto &Occurrence : Plan.currentOccurrences())
                  if (Occurrence.Disposition ==
                          jeandle::pea::FinalDeoptPoolOccurrenceDisposition::
                              RemovedByPruning &&
                      Occurrence.SemanticCell &&
                      *Occurrence.SemanticCell == SemanticCell &&
                      Result.currentIdentityRepresentsSource(
                          Occurrence.CurrentID, ID))
                    return true;
              }
              return false;
            });
        if (HasSurvivingUse) {
          markIneligible(ID, /*FreshRetry=*/true);
          AnyChange = true;
        }
      }
      // Path-sensitive ordinary-state cascade. Visited defends cycles
      // (a.f=b, b.g=a).
      {
        SmallVector<jeandle::ObjectID, 8> WList;
        DenseSet<jeandle::ObjectID> VSet;
        for (auto &Kv : Eligible)
          if (!Kv.second)
            WList.push_back(Kv.first);
        while (!WList.empty()) {
          jeandle::ObjectID Cur = WList.pop_back_val();
          if (!VSet.insert(Cur).second)
            continue;
          if (Eligible[Cur]) {
            Eligible[Cur] = false;
            AnyChange = true;
          }
          // Synthetic Case-C source cascade (was markIneligible's): a
          // synthetic VO kept real must also keep its per-pred sources real
          // (their per-pred stores were eliminated in favor of the synthetic
          // merge PHI).
          if (Cur < Result.VirtualObjects.size() &&
              Result.VirtualObjects[Cur]->IsSynthetic)
            for (jeandle::ObjectID Src :
                 Result.VirtualObjects[Cur]->SyntheticSourceIDs)
              if (Src != jeandle::InvalidObjectID)
                WList.push_back(Src);
          // Path-sensitive live VirtualRef definitions.
          if (auto EIt = LiveVirtualRefDeps.find(Cur);
              EIt != LiveVirtualRefDeps.end())
            for (jeandle::ObjectID Inner : EIt->second)
              WList.push_back(Inner);
        }
      }
      // Availability sweep: rebuild the owned-PHI set from the effects
      // that survive the CURRENT eligibility set, then keep every VO whose
      // effects reference unavailable values real.
      {
        DenseSet<Value *> OwnedPhis;
        for (const auto &Kv : Result.BlockEffects)
          for (const auto &E : Kv.second)
            if (const auto *PE = dyn_cast<jeandle::CreatePHIEffect>(&E))
              if (E.hasMutationOwner() && Eligible.lookup(E.getMutationOwner()))
                OwnedPhis.insert(PE->PhiInst);
        for (auto &VObjUP : Result.VirtualObjects) {
          jeandle::ObjectID ID = VObjUP->getID();
          if (!Eligible.lookup(ID))
            continue;
          if (!FieldValuesAvailable(ID, OwnedPhis)) {
            Eligible[ID] = false;
            AnyChange = true;
          }
        }
        for (const auto &[Safepoint, Pool] : PoolsAt) {
          bool InvalidMember =
              llvm::any_of(Pool->getPlan().graph().currentMembers(),
                           [&](jeandle::pea::CurrentDeoptNodeID CurrentID) {
                             jeandle::ObjectID ID =
                                 static_cast<jeandle::ObjectID>(CurrentID);
                             return ID >= Result.VirtualObjects.size() ||
                                    !Eligible.lookup(ID);
                           });
          if (InvalidMember || !PoolTokensAvailable(*Pool, OwnedPhis))
            LateInvalidDeoptPools.insert(Safepoint);
        }
      }
    }
  }

  for (const auto &KV : BlockExits)
    if (KV.second.IsDead)
      Result.FinalDeadBlocks.insert(KV.first);

  // Iterate by dense ObjectID order for determinism. The only remaining
  // post-pass cleanup is dropping effects for objects that became
  // ineligible during the walk (lock imbalance above; nested-virtual
  // discovery; access-handler type mismatch / non-const offset; etc.).
  // Cross-block escapes trigger materialization (they do not disqualify an
  // object).
  DenseSet<jeandle::ObjectID> IneligibleIDs;
  for (auto &VObjUP : Result.VirtualObjects) {
    jeandle::ObjectID ID = VObjUP->getID();
    auto EIt = Eligible.find(ID);
    bool IsEligible = (EIt != Eligible.end()) && EIt->second;
    if (!IsEligible)
      IneligibleIDs.insert(ID);
  }
  dropEffectsForIneligible(IneligibleIDs);

  // -------------------------------------------------------------------------
  // EscapeClassification population.
  //
  // dropEffectsForIneligible() already stamped AlwaysEscapes onto every
  // ineligible VO. For each surviving (eligible) VO, classify based on whether
  // ANY Materialize effect survived in the committed plan:
  //   * no Materialize  -> NeverEscapes      (alloc fully eliminated)
  //   * any Materialize -> PartiallyEscapes  (original allocation retained;
  //                                           tracked fields and locks replayed
  //                                           at each required escape)
  // Maps to NEVER vs PARTIAL vs ALWAYS escape classification.
  // -------------------------------------------------------------------------
  DenseSet<jeandle::ObjectID> HasSurvivingMaterialize;
  for (const auto &Kv : Result.BlockEffects) {
    for (const auto &E : Kv.second) {
      if (isa<jeandle::MaterializeEffect>(E) && E.hasMutationOwner())
        HasSurvivingMaterialize.insert(E.getMutationOwner());
    }
  }

  // Synthetic preparation is monotonic so loop retries can reuse validated
  // identity DAGs, but allocation retention is a property of the final effect
  // plan.  Starting from the synthetic Materialize effects that actually
  // survived loop rollback, compute the exact prepared-synthetic/source-leaf
  // closure needed by the committed transform.  A prepared DAG whose
  // speculative materialization was rolled back must not keep otherwise
  // non-escaping source allocations alive.
  DenseSet<jeandle::ObjectID> LivePreparedSyntheticIDs;
  DenseSet<jeandle::ObjectID> LiveKeptSyntheticSourceAllocations;
  ComputeLivePreparedSyntheticClosure(HasSurvivingMaterialize,
                                      LivePreparedSyntheticIDs,
                                      LiveKeptSyntheticSourceAllocations);

  for (auto &VObjUP : Result.VirtualObjects) {
    jeandle::ObjectID ID = VObjUP->getID();
    // dropEffectsForIneligible stamped AlwaysEscapes; skip those VOs.
    if (Result.EscapeClassification.count(ID))
      continue;
    // A live prepared synthetic DAG routes these ordinary allocations through
    // one or more SyntheticPhi identities. Keep the original allocation
    // invokes (and therefore their allocation-site deopt bundles) without
    // replaying source fields or locks; the synthetic's point-local
    // MaterializeEffect performs the one complete replay when that identity
    // actually escapes.
    if (LiveKeptSyntheticSourceAllocations.count(ID)) {
      Result.EscapeClassification[ID] =
          jeandle::PEAResult::EscapeKind::PartiallyEscapes;
      continue;
    }
    // Classify every live synthetic node in the prepared identity closure as
    // partial so downstream Case-B pointer PHIs keep routing its now-real
    // SyntheticPhi identity instead of being erased as poison.
    if (VObjUP->IsSynthetic && LivePreparedSyntheticIDs.count(ID)) {
      Result.EscapeClassification[ID] =
          jeandle::PEAResult::EscapeKind::PartiallyEscapes;
      continue;
    }
    Result.EscapeClassification[ID] =
        HasSurvivingMaterialize.count(ID)
            ? jeandle::PEAResult::EscapeKind::PartiallyEscapes
            : jeandle::PEAResult::EscapeKind::NeverEscapes;
  }

  // For every VO that ended up NeverEscapes (alloc will be
  // EliminateAllocation'd and its OrigAlloc users will RAUW to poison in the
  // cfg-kill phase), schedule the Case-B aliased PHIs for explicit erasure.
  // The transform's post-cfg-kill hook walks Result.CaseBAliasedPhisToErase and
  // runs RAUW(poison) + eraseFromParent on each surviving handle.
  // We deliberately do NOT schedule erasure for PartiallyEscapes or
  // AlwaysEscapes VOs: there, the PHI still routes a live materialized
  // pointer (or the OrigAlloc itself) and erasing would corrupt SSA.
  for (auto &Kv : CaseBPhiAliases) {
    jeandle::ObjectID ID = Kv.first;
    auto CIt = Result.EscapeClassification.find(ID);
    if (CIt == Result.EscapeClassification.end())
      continue;
    if (CIt->second != jeandle::PEAResult::EscapeKind::NeverEscapes)
      continue;
    for (PHINode *Phi : Kv.second) {
      if (!Phi)
        continue;
      Result.CaseBAliasedPhisToErase.emplace_back(Phi);
    }
  }
  // Count of allocations actually eliminated by PEA. Only NeverEscapes VOs
  // have their OrigAlloc erased by the transform (PartiallyEscapes keeps
  // OrigAlloc alive as the materialized value, and AlwaysEscapes were never
  // virtualized), so count NeverEscapes VOs — NOT every surviving
  // EliminateAllocationEffect, which would over-count the PartiallyEscapes
  // ones the transform's EliminateAllocationEffect::apply suppresses via its
  // EscapeClassification early-return.
  unsigned EliminatedAllocs = 0;
  for (const auto &Kv : Result.EscapeClassification)
    if (!Result.VirtualObjects[Kv.first]->IsSynthetic &&
        Kv.second == jeandle::PEAResult::EscapeKind::NeverEscapes)
      ++EliminatedAllocs;
  AttemptStats.Eliminated += EliminatedAllocs;
}

// Post-commit audit of every deopt obligation the transform must satisfy.
// Resolves each deopt-bundle value through the final replace-effect chains;
// rejects plans whose tracked values are unavailable, or that resolve to a
// NeverEscapes VO identity (the cfg-kill phase RAUWs that OrigAlloc to poison,
// so a forwarded reference would become a poison store that canonicalization
// then deletes). Handles orphan pools (no safepoint target), duplicate pools at
// the same safepoint, late-invalid pools, and serialization failure. Also
// audits replay values of surviving Materialize/CreatePHI effects, since those
// are replayed at apply time and carry the same obligation as a deopt root.
// Every failure records the underlying ordinary allocation sites into
// InvalidDeoptAllocationSites so the outer fresh-retry loop can suppress them
// and rebuild with the referenced allocation kept real.
void Analyzer::validateFinalDeoptObligations() {
  using namespace jeandle::pea;

  InvalidDeoptObligation = false;
  InvalidDeoptAllocationSites.clear();

  DenseMap<Instruction *, const jeandle::Effect *> EarliestReplFor;
  DenseMap<Instruction *, const jeandle::EliminateAllocationEffect *>
      EarliestAllocElimFor;
  DenseMap<CallBase *, SmallVector<const jeandle::RewriteDeoptPoolEffect *, 2>>
      PoolsAt;
  SmallVector<const jeandle::RewriteDeoptPoolEffect *, 2> OrphanPools;
  DenseSet<Value *> OwnedPhis;

  for (const auto &KV : Result.BlockEffects)
    for (const jeandle::Effect &E : KV.second) {
      Instruction *Target = E.getTarget();
      if (Target && (isa<jeandle::ReplaceLoadEffect>(E) ||
                     isa<jeandle::ReplaceCallEffect>(E))) {
        auto [It, Inserted] = EarliestReplFor.try_emplace(Target, &E);
        if (!Inserted && E.SeqNo < It->second->SeqNo)
          It->second = &E;
      }
      if (Target)
        if (const auto *AE = dyn_cast<jeandle::EliminateAllocationEffect>(&E)) {
          auto [It, Inserted] = EarliestAllocElimFor.try_emplace(Target, AE);
          if (!Inserted && AE->SeqNo < It->second->SeqNo)
            It->second = AE;
        }
      if (const auto *PE = dyn_cast<jeandle::CreatePHIEffect>(&E))
        if (E.hasMutationOwner())
          OwnedPhis.insert(PE->PhiInst);
      if (const auto *Pool = dyn_cast<jeandle::RewriteDeoptPoolEffect>(&E)) {
        auto *Safepoint = dyn_cast_or_null<CallBase>(Pool->getTarget());
        if (Safepoint)
          PoolsAt[Safepoint].push_back(Pool);
        else
          OrphanPools.push_back(Pool);
      }
    }

  // Follows a value through the earliest (lowest-SeqNo) ReplaceLoad/ReplaceCall
  // chain, classifying the terminal as a resolved value, a dependency-free oop
  // handle, or a deleted (poison/unused) call.
  auto ResolveFinalValue = [&](Value *Root) -> FinalValue {
    Value *Current = Root;
    SmallPtrSet<Value *, 8> Seen;
    while (Current && Seen.insert(Current).second) {
      auto *Target = dyn_cast<Instruction>(Current);
      if (!Target)
        break;
      auto It = EarliestReplFor.find(Target);
      if (It == EarliestReplFor.end())
        break;
      const jeandle::Effect *E = It->second;
      if (const auto *RE = dyn_cast<jeandle::ReplaceLoadEffect>(E)) {
        if (!RE->Replacement)
          break;
        Current = RE->Replacement;
        continue;
      }
      const auto *CallRE = cast<jeandle::ReplaceCallEffect>(E);
      if (CallRE->OopHandleId >= 0)
        return {FinalValue::DependencyFreeOopHandle, nullptr};
      if (!CallRE->Replacement)
        return {FinalValue::Deleted, nullptr};
      Current = CallRE->Replacement;
    }
    return {FinalValue::ResolvedValue, Current};
  };

  DenseMap<Value *, jeandle::ObjectID> ObjectIdentity;
  for (const auto &VObjUP : Result.VirtualObjects) {
    const jeandle::VirtualObject &VObj = *VObjUP;
    Value *Identity = VObj.IsSynthetic ? static_cast<Value *>(VObj.SyntheticPhi)
                                       : (Value *)VObj.AllocationCall;
    if (Identity)
      ObjectIdentity.try_emplace(Identity, VObj.getID());
  }

  SmallPtrSet<CallBase *, 8> RecordedAllocationSites;
  // Walks a (possibly synthetic) VO subtree and records every ordinary
  // (non-synthetic) allocation-call site into InvalidDeoptAllocationSites, so a
  // rejected plan reports the real source allocations the retry must suppress.
  auto CollectOrdinarySites = [&](jeandle::ObjectID RootID) {
    DenseSet<jeandle::ObjectID> Visited;
    SmallVector<jeandle::ObjectID, 8> Worklist(1, RootID);
    while (!Worklist.empty()) {
      jeandle::ObjectID ID = Worklist.pop_back_val();
      if (ID == jeandle::InvalidObjectID ||
          ID >= Result.VirtualObjects.size() || !Visited.insert(ID).second)
        continue;
      const jeandle::VirtualObject &VObj = *Result.VirtualObjects[ID];
      if (VObj.IsSynthetic) {
        Worklist.append(VObj.SyntheticSourceIDs.begin(),
                        VObj.SyntheticSourceIDs.end());
        continue;
      }
      auto *Site = dyn_cast_or_null<CallBase>((Value *)VObj.AllocationCall);
      if (Site && RecordedAllocationSites.insert(Site).second)
        InvalidDeoptAllocationSites.push_back(Site);
    }
  };

  auto RejectVirtualObject = [&](jeandle::ObjectID ID) {
    InvalidDeoptObligation = true;
    CollectOrdinarySites(ID);
  };
  auto RejectPool = [&](const jeandle::RewriteDeoptPoolEffect &Pool) {
    InvalidDeoptObligation = true;
    for (CurrentDeoptNodeID CurrentID : Pool.getPlan().graph().currentMembers())
      CollectOrdinarySites(static_cast<jeandle::ObjectID>(CurrentID));
    for (const FinalDeoptPoolCurrentOccurrence &Occurrence :
         Pool.getPlan().currentOccurrences())
      CollectOrdinarySites(
          static_cast<jeandle::ObjectID>(Occurrence.CurrentID));
  };

  for (const jeandle::RewriteDeoptPoolEffect *Pool : OrphanPools)
    RejectPool(*Pool);

  // Walks a VO subtree and rejects any ordinary VO whose escape classification
  // is NeverEscapes — its OrigAlloc is RAUW'd to poison, so a deopt/replay
  // value resolving to that identity would be unsound. Synthetic VOs are
  // traversed to their source IDs.
  auto AuditObjectIdentity = [&](jeandle::ObjectID RootID) {
    DenseSet<jeandle::ObjectID> Visited;
    SmallVector<jeandle::ObjectID, 8> Worklist(1, RootID);
    while (!Worklist.empty()) {
      jeandle::ObjectID ID = Worklist.pop_back_val();
      if (ID == jeandle::InvalidObjectID ||
          ID >= Result.VirtualObjects.size() || !Visited.insert(ID).second)
        continue;
      const jeandle::VirtualObject &VObj = *Result.VirtualObjects[ID];
      if (VObj.IsSynthetic) {
        Worklist.append(VObj.SyntheticSourceIDs.begin(),
                        VObj.SyntheticSourceIDs.end());
        continue;
      }
      auto CIt = Result.EscapeClassification.find(ID);
      if (CIt != Result.EscapeClassification.end() &&
          CIt->second == jeandle::PEAResult::EscapeKind::NeverEscapes)
        RejectVirtualObject(ID);
    }
  };

  // Resolves a deopt/replay root through the replace-effect chain, then walks
  // its transitive operands: any operand that resolves to a VO identity is
  // audited via AuditObjectIdentity; allocation invokes and selected intrinsics
  // (launder/strip invariant group, ptr annotation) are recognized as sound.
  std::function<void(Value *)> AuditValue = [&](Value *Root) {
    SmallPtrSet<Value *, 32> Visited;
    SmallVector<Value *, 16> Worklist(1, Root);
    while (!Worklist.empty()) {
      Value *Current = Worklist.pop_back_val();
      if (!Current)
        continue;
      FinalValue Final = ResolveFinalValue(Current);
      if (Final.K == FinalValue::Deleted ||
          Final.K == FinalValue::DependencyFreeOopHandle)
        continue;
      Current = Final.V;
      if (!Current || !Visited.insert(Current).second)
        continue;
      if (auto It = ObjectIdentity.find(Current); It != ObjectIdentity.end()) {
        AuditObjectIdentity(It->second);
        continue;
      }
      if (auto *CB = dyn_cast<CallBase>(Current))
        if (isJeandleAllocation(CB))
          continue;
      if (auto *II = dyn_cast<IntrinsicInst>(Current)) {
        Intrinsic::ID IID = II->getIntrinsicID();
        if (IID == Intrinsic::launder_invariant_group ||
            IID == Intrinsic::strip_invariant_group ||
            IID == Intrinsic::ptr_annotation) {
          Worklist.push_back(II->getArgOperand(0));
          continue;
        }
      }
      if (isa<CallBase>(Current))
        continue;
      if (auto *U = dyn_cast<User>(Current))
        for (Value *Operand : U->operand_values())
          Worklist.push_back(Operand);
    }
  };

  auto IsAvailableValue = [&](Value *Root) {
    SmallPtrSet<Value *, 8> Visited;
    SmallVector<Value *, 8> Worklist(1, Root);
    while (!Worklist.empty()) {
      Value *Current = Worklist.pop_back_val();
      if (!Current || !Visited.insert(Current).second)
        continue;
      auto *I = dyn_cast<Instruction>(Current);
      if (!I || I->getParent())
        continue;
      if (auto *PN = dyn_cast<PHINode>(I)) {
        if (OwnedPhis.contains(PN))
          continue;
        return false;
      }
      for (Value *Operand : I->operand_values())
        Worklist.push_back(Operand);
    }
    return true;
  };

  // True iff the safepoint call is fully replaced or eliminated by the plan: a
  // surviving ReplaceCall with no/constant/argument replacement (or an oop-
  // handle rewrite), or a NeverEscapes-owned EliminateAllocation. Such a
  // safepoint cannot deopt, so it carries no deopt obligation.
  auto SafepointDeleted = [&](CallBase *CB) {
    if (const auto *Replace = dyn_cast_or_null<jeandle::ReplaceCallEffect>(
            EarliestReplFor.lookup(CB))) {
      Value *Replacement = Replace->Replacement;
      if (Replace->getTarget() == CB && !isJeandleMonitorEnter(CB) &&
          ((!Replacement && CB->use_empty()) || Replace->OopHandleId >= 0 ||
           isa_and_nonnull<Constant>(Replacement) ||
           isa_and_nonnull<Argument>(Replacement)))
        return true;
    }
    const auto *AE = EarliestAllocElimFor.lookup(CB);
    if (!AE || !AE->hasMutationOwner())
      return false;
    auto CIt = Result.EscapeClassification.find(AE->getMutationOwner());
    return CIt != Result.EscapeClassification.end() &&
           CIt->second == jeandle::PEAResult::EscapeKind::NeverEscapes;
  };

  for (Instruction &I : instructions(F)) {
    auto *CB = dyn_cast<CallBase>(&I);
    if (!CB || !hasDeoptBundle(CB) || SafepointDeleted(CB))
      continue;
    auto ExitIt = BlockExits.find(CB->getParent());
    if (ExitIt != BlockExits.end() && ExitIt->second.IsDead)
      continue;

    auto PoolIt = PoolsAt.find(CB);
    if (PoolIt != PoolsAt.end()) {
      const jeandle::RewriteDeoptPoolEffect *Pool = nullptr;
      const auto &PoolEffects = PoolIt->second;
      if (PoolEffects.size() != 1) {
        for (const jeandle::RewriteDeoptPoolEffect *Duplicate : PoolEffects)
          RejectPool(*Duplicate);
      } else {
        Pool = PoolEffects.front();
      }

      bool PoolValid = Pool != nullptr;
      if (!Pool)
        continue;
      if (LateInvalidDeoptPools.contains(CB))
        PoolValid = false;
      for (CurrentDeoptNodeID CurrentID :
           Pool->getPlan().graph().currentMembers()) {
        jeandle::ObjectID ID = static_cast<jeandle::ObjectID>(CurrentID);
        if (ID >= Result.VirtualObjects.size() || !Eligible.lookup(ID)) {
          PoolValid = false;
          break;
        }
      }
      for (const FinalDeoptPoolBundleToken &Token : Pool->getPlan().tokens()) {
        if (Token.kind() != FinalDeoptPoolBundleTokenKind::TrackedValue)
          continue;
        Value *Tracked = Token.trackedValue();
        if (!Tracked || !IsAvailableValue(Tracked))
          PoolValid = false;
        AuditValue(Tracked);
      }
      SerializeFinalDeoptPoolBundleResult Serialized =
          serializeFinalDeoptPoolBundlePlan(Pool->getPlan(), *CB);
      if (!Serialized.Inputs)
        PoolValid = false;
      if (!PoolValid)
        RejectPool(*Pool);
      // The immutable final token stream is the exact dependency set. Source
      // cells removed by pruning must not be resurrected by auditing the
      // original bundle after a successful whole-pool plan.
      continue;
    }

    auto Deopt = CB->getOperandBundle(LLVMContext::OB_deopt);
    assert(Deopt && "hasDeoptBundle lied");
    for (const Use &Input : Deopt->Inputs)
      AuditValue(Input.get());
  }

  // A surviving Materialize / CreatePHI effect replays its recorded field
  // values at apply time, so each replay value carries the same closure
  // obligation as a deopt root: it must not resolve to a NeverEscapes VO's
  // identity, whose OrigAlloc the cfg-kill phase RAUWs to poison — a replayed
  // reference would become a poison store that canonicalization then deletes,
  // silently dropping the field write. Jeandle's analysis/transform split plus
  // un-virtualize decisions and loop-fixpoint eligibility rollback can strand
  // such a reference, so audit it here and rebuild with the referenced
  // allocation kept real.
  for (const auto &KV : Result.BlockEffects) {
    for (const jeandle::Effect &E : KV.second) {
      if (const auto *ME = dyn_cast<jeandle::MaterializeEffect>(&E)) {
        for (const auto &FE : ME->FieldEntries) {
          if (FE.Value.isScalar())
            AuditValue(FE.Value.getScalar());
          else if (FE.Value.isMaterializedRef())
            AuditValue(FE.Value.getMaterialized());
        }
      } else if (const auto *PE = dyn_cast<jeandle::CreatePHIEffect>(&E)) {
        for (const WeakTrackingVH &In : PE->PHIIncomingValues)
          AuditValue(In);
      }
    }
  }
}

// Validates every recorded CFG deadness proof against the final plan and
// returns all invalid killers at once (rather than one terminator per retry,
// which re-analyzed large methods O(#recorded-proofs) times). A folded
// branch/switch condition must still resolve to a ConstantInt selecting the
// same successor; a folded invoke needs a surviving ReplaceCall effect; an
// eliminated-allocation invoke needs a surviving EliminateAllocation whose
// owner is NeverEscapes. Any killer failing its proof is collected so the
// outer fresh-retry loop can suppress them all in one restart.
SmallVector<Instruction *, 8> Analyzer::validateCFGDeadnessProofs() const {
  // Precompute the earliest (lowest SeqNo) ReplaceLoad/ReplaceCall effect and
  // the earliest EliminateAllocationEffect per target instruction in a single
  // pass, so each proof validates with O(1) lookups instead of rescanning all
  // BlockEffects per proof.
  DenseMap<Instruction *, const jeandle::Effect *> EarliestReplFor;
  DenseMap<Instruction *, const jeandle::EliminateAllocationEffect *>
      EarliestAllocElimFor;
  for (const auto &KV : Result.BlockEffects)
    for (const jeandle::Effect &E : KV.second) {
      Instruction *T = E.getTarget();
      if (!T)
        continue;
      if (isa<jeandle::ReplaceLoadEffect>(E) ||
          isa<jeandle::ReplaceCallEffect>(E)) {
        auto [It, Inserted] = EarliestReplFor.try_emplace(T, &E);
        if (!Inserted && E.SeqNo < It->second->SeqNo)
          It->second = &E;
      }
      if (const auto *AE = dyn_cast<jeandle::EliminateAllocationEffect>(&E)) {
        auto [It, Inserted] = EarliestAllocElimFor.try_emplace(T, AE);
        if (!Inserted && AE->SeqNo < It->second->SeqNo)
          It->second = AE;
      }
    }

  SmallVector<Instruction *, 8> InvalidKillers;
  auto RecordIfInvalid = [&](Instruction *Killer) {
    if (Killer)
      InvalidKillers.push_back(Killer);
  };

  for (const CFGDeadnessProof &Proof : CFGDeadnessProofs) {
    switch (Proof.Kind) {
    case CFGDeadnessProofKind::FoldedTerminatorCondition: {
      Value *Current = Proof.Condition;
      SmallPtrSet<Value *, 4> Seen;
      while (Current && Seen.insert(Current).second) {
        auto *Target = dyn_cast<Instruction>(Current);
        if (!Target)
          break;
        auto It = EarliestReplFor.find(Target);
        if (It == EarliestReplFor.end())
          break;
        const jeandle::Effect *E = It->second;
        Value *Replacement = nullptr;
        if (const auto *RE = dyn_cast<jeandle::ReplaceLoadEffect>(E))
          Replacement = RE->Replacement;
        else
          Replacement = cast<jeandle::ReplaceCallEffect>(E)->Replacement;
        if (!Replacement)
          break;
        Current = Replacement;
      }
      auto *CI = dyn_cast_or_null<ConstantInt>(Current);
      if (!CI) {
        InvalidKillers.push_back(Proof.Killer);
        break;
      }
      BasicBlock *Chosen = nullptr;
      if (auto *BI = dyn_cast<BranchInst>(Proof.Killer))
        Chosen = BI->getSuccessor(CI->isZero() ? 1 : 0);
      else if (auto *SI = dyn_cast<SwitchInst>(Proof.Killer))
        Chosen = SI->findCaseValue(CI)->getCaseSuccessor();
      else {
        InvalidKillers.push_back(Proof.Killer);
        break;
      }
      if (Chosen != Proof.ChosenSuccessor)
        InvalidKillers.push_back(Proof.Killer);
      break;
    }
    case CFGDeadnessProofKind::FoldedInvoke: {
      auto It = EarliestReplFor.find(Proof.Killer);
      RecordIfInvalid(It == EarliestReplFor.end() ||
                              !isa<jeandle::ReplaceCallEffect>(It->second)
                          ? Proof.Killer
                          : nullptr);
      break;
    }
    case CFGDeadnessProofKind::EliminatedAllocationInvoke: {
      auto It = EarliestAllocElimFor.find(Proof.Killer);
      if (It == EarliestAllocElimFor.end()) {
        InvalidKillers.push_back(Proof.Killer);
        break;
      }
      if (!It->second->hasMutationOwner()) {
        InvalidKillers.push_back(Proof.Killer);
        break;
      }
      auto CIt =
          Result.EscapeClassification.find(It->second->getMutationOwner());
      RecordIfInvalid(CIt == Result.EscapeClassification.end() ||
                              CIt->second !=
                                  jeandle::PEAResult::EscapeKind::NeverEscapes
                          ? Proof.Killer
                          : nullptr);
      break;
    }
    }
  }
  return InvalidKillers;
}

void Analyzer::publishAttemptOutputs() {
  AttemptStats.publish();
  Result.publishEffectTrace();

  if (JeandleDumpPEAStats) {
    unsigned NeverEsc = 0, PartialEsc = 0, AlwaysEsc = 0;
    for (const auto &Kv : Result.EscapeClassification) {
      // Synthetic Case-C VOs have no allocation site.  Count only the real
      // source allocations in allocation escape statistics.
      if (Result.VirtualObjects[Kv.first]->IsSynthetic)
        continue;
      switch (Kv.second) {
      case jeandle::PEAResult::EscapeKind::NeverEscapes:
        ++NeverEsc;
        break;
      case jeandle::PEAResult::EscapeKind::PartiallyEscapes:
        ++PartialEsc;
        break;
      case jeandle::PEAResult::EscapeKind::AlwaysEscapes:
        ++AlwaysEsc;
        break;
      }
    }
    llvm::errs() << ";; PEA stats @" << F.getName()
                 << ": NeverEscapes=" << NeverEsc
                 << " PartiallyEscapes=" << PartialEsc
                 << " AlwaysEscapes=" << AlwaysEsc << "\n";
  }
}

// Preorder (outer-first) collection of all loops reachable from L. Determinism
// follows LoopInfo::iterator / Loop::getSubLoops ordering, which mirrors the
// source-IR block order.
static void collectLoopsPreorder(Loop *L, SmallVectorImpl<Loop *> &Out) {
  Out.push_back(L);
  for (Loop *Sub : L->getSubLoops())
    collectLoopsPreorder(Sub, Out);
}

// Overflow recovery drains the outer virtual state at the loop preheader before
// retrying the nest in MaterializeAll mode. Normally, processLoop computes the
// B/B' fixpoint and virtual objects may remain virtual across backedges; the
// separate unvisited-loop safety net drains only loops that the RPO recursion
// never processed.

void Analyzer::processStateBeforeLoopOnOverflow(Loop *L) {
  // Every VO still virtual at the loop's forward end (preheader exit) is
  // forcibly materialised, so the re-do of the loop body in
  // MATERIALIZE_ALL mode starts from a clean "no live virtuals on entry"
  // state.
  BasicBlock *PH = L->getLoopPreheader();
  if (!PH)
    return;
  assert(
      !isa<InvokeInst>(PH->getTerminator()) &&
      "loop preheader has exactly one successor; cannot terminate in invoke");
  auto It = BlockExits.find(PH);
  if (It == BlockExits.end())
    return;
  BlockExitInfo &PHExit = It->second;
  SmallVector<jeandle::ObjectID, 4> Vs(PHExit.Virtuals.begin(),
                                       PHExit.Virtuals.end());
  llvm::sort(Vs);
  for (jeandle::ObjectID ID : Vs) {
    if (!Eligible.lookup(ID))
      continue;
    materializeAtPredFromExitInfo(ID, PH, PHExit, /*EdgeLocal=*/false,
                                  MatReason::LoopExit);
  }
}

void Analyzer::materializePreheaderVirtualsForUnvisitedLoops() {
  SmallVector<Loop *, 8> AllLoops;
  for (Loop *L : LI)
    collectLoopsPreorder(L, AllLoops);

  for (Loop *L : AllLoops) {
    BasicBlock *PH = L->getLoopPreheader();
    if (!PH) {
      // processLoop handles loops without a unique preheader by marking every
      // VO live at a forward header predecessor ineligible, preserving the
      // original IR. This safety net cannot select a unique drain point, so it
      // has nothing further to do here.
      continue;
    }
    assert(
        !isa<InvokeInst>(PH->getTerminator()) &&
        "loop preheader has exactly one successor; cannot terminate in invoke");
    // Strict gate on VisitedLoops. Every loop processLoop touched —
    // whether the body fixpoint converged, fell into the pessimistic
    // MATERIALIZE_ALL fallback, or hit the overflow-recovery retry path
    // — was already handled by processLoop. Converged loops need no drain.
    // The only loops that need this safety-net drain are those
    // processLoop never visited (an unreachable top-level loop the RPO
    // walk skipped, or a sub-loop whose outer recursion returned early
    // on OverflowFlag).
    if (VisitedLoops.count(L))
      continue;
    auto It = BlockExits.find(PH);
    if (It == BlockExits.end())
      continue;
    BlockExitInfo &PHExit = It->second;

    // Snapshot+sort the virtual IDs to materialize. Sorting by ObjectID gives
    // deterministic effect ordering across runs.
    SmallVector<jeandle::ObjectID, 4> Vs(PHExit.Virtuals.begin(),
                                         PHExit.Virtuals.end());
    llvm::sort(Vs);
    for (jeandle::ObjectID ID : Vs) {
      if (!Eligible.lookup(ID))
        continue;
      materializeAtPredFromExitInfo(ID, PH, PHExit, /*EdgeLocal=*/false,
                                    MatReason::LoopExit);
    }
  }
}

bool Analyzer::isReplayEdgeSupported(BasicBlock *PH,
                                     BasicBlock *TargetMerge) const {
  if (!PH || !TargetMerge)
    return false;
  Instruction *Term = PH->getTerminator();
  SmallVector<BasicBlock *, 4> DistinctSuccessors;
  bool ReachesTarget = false;
  for (BasicBlock *Succ : successors(PH)) {
    ReachesTarget |= Succ == TargetMerge;
    if (!llvm::is_contained(DistinctSuccessors, Succ))
      DistinctSuccessors.push_back(Succ);
  }
  // A callbr is itself side-effecting: even with one distinct destination,
  // replay before its terminator is not equivalent to replay on the outgoing
  // edge after the asm call.
  if (!ReachesTarget || isa<CallBrInst>(Term))
    return false;
  return DistinctSuccessors.size() <= 1 ||
         (!isa<IndirectBrInst>(Term) && TargetMerge->canSplitPredecessors());
}

// Predecessor-edge / preheader-drain wrapper around the shared
// ensureMaterialized core. Unlike materializeAt (the escape-point path), this
// variant operates against a predecessor's BlockExitInfo snapshot rather than
// the analyzer's current per-block state, which has moved on by the time the
// unvisited-loop safety net runs. The function-wide MaterializedAtPred map
// dedups (and breaks cycles between) recursive nested-virtual materializations
// within a single PH and across multiple call sites (e.g. a mixed-state merge
// and a loop-preheader sweep at the same PH).
//
// TargetMerge is the merge block this materialize is destined for (the
// MergeProcessor::BB in scope), or null for a true block-end drain. It keys
// MaterializedAtPred so distinct target merges each get their own incoming-
// edge replay at the same PH.
//
// The two forms this function encodes:
//  - Incoming-edge mat (EdgeLocal=true): analysis records PH->TargetMerge
//    provenance and flips the target-local contributionFor view, while leaving
//    the shared `BlockExits[PH]` snapshot unchanged. The transform splits the
//    edge when PH has another distinct successor, then emits every replay side
//    effect in the dedicated block. OrigAlloc is reused as the value and
//    already dominates the edge.
//  - Block-end drain (EdgeLocal=false): replay intentionally applies to every
//    successor and the shared ExitInfo is flipped. Overflow recovery and the
//    truly-unvisited-loop safety net use this form to start subsequent
//    processing with no virtual object live at the loop entry.
void Analyzer::materializeAtPredFromExitInfo(jeandle::ObjectID ID,
                                             BasicBlock *PH,
                                             BlockExitData &ExitInfo,
                                             bool EdgeLocal, MatReason Reason,
                                             BasicBlock *TargetMerge) {
  const bool IsPlanRoot =
      ActiveMaterializationPlanID == jeandle::MaterializeEffect::InvalidPlanID;
  if (IsPlanRoot)
    ActiveMaterializationPlanID = NextMaterializationPlanID++;
  auto FinishPlan = llvm::make_scope_exit([&] {
    if (IsPlanRoot)
      ActiveMaterializationPlanID = jeandle::MaterializeEffect::InvalidPlanID;
  });

  // A per-predecessor materialization is an incoming-edge effect.  Most LLVM
  // terminators can be split by SplitBlockPredecessors, including invoke
  // unwind edges into landingpads.  IndirectBr and EH pads that explicitly
  // reject predecessor splitting cannot carry an edge-local replay safely;
  // keep the object real before emitting any cascade, field, or lock effect.
  if (EdgeLocal && TargetMerge) {
    if (!isReplayEdgeSupported(PH, TargetMerge)) {
      LLVM_DEBUG(dbgs() << "PEA: keep-real unsupported replay edge VO=" << ID
                        << " from " << PH->getName() << " to "
                        << TargetMerge->getName() << "\n");
      observeFieldDefinitions(ID, ExitInfo.FieldDefinitions);
      markIneligible(ID, /*FreshRetry=*/true);
      return;
    }
  }

  auto ClearLockState = [&](jeandle::ObjectID Oid) {
    LockCounts[Oid] = 0;
    LiveLockEnters.erase(Oid);
    // A block-end drain clears the shared ExitInfo's lock state — the flip
    // makes the VO materialized, so the lock state is irrelevant. Edge-local:
    // do not clear the target-local ExitInfo until the replay effect has
    // captured the lock stack. FlipState clears the complete per-object view
    // afterward, while sibling successors continue to use the shared
    // predecessor snapshot.
    // The pred's locks are captured into
    // the Materialize effect once (on first emit); the retry's dedup skips
    // re-capture.
    if (!EdgeLocal) {
      ExitInfo.LockCounts.erase(Oid);
      ExitInfo.LiveLockEnters.erase(Oid);
    }
  };
  auto ComputeSafeIP = [&]() -> Instruction * {
    // Per-predecessor placement: materialize at the predecessor's terminator.
    // The replay receiver normally dominates the terminator. An allocation
    // invoke result is instead available on its normal edge; the availability
    // gate recognizes that exact edge and the transform splits it before
    // emitting any replay operations.
    return PH->getTerminator();
  };
  auto FlipState = [&](jeandle::ObjectID Oid) {
    // Incoming-edge replay flips only the target-local exit view supplied by
    // contributionFor. A block-end drain applies to every successor and flips
    // the shared predecessor snapshot supplied directly by its caller.
    if (EdgeLocal) {
      markObjectMaterializedDispositionInExitData(ExitInfo, Oid);
      return;
    }
    ExitInfo.Virtuals.erase(Oid);
    ExitInfo.Materialized.insert(Oid);
    ExitInfo.FieldStates.erase(Oid);
    ExitInfo.FieldDefinitions.erase(Oid);
    ExitInfo.LockCounts.erase(Oid);
  };

  auto Recurse = [&](jeandle::ObjectID Oid, MatReason R) {
    materializeAtPredFromExitInfo(Oid, PH, ExitInfo, EdgeLocal, R, TargetMerge);
  };
  auto CaptureLocksIntoEffect = [](ArrayRef<LockEnter> Stack, jeandle::ObjectID,
                                   jeandle::MaterializeEffect &E) {
    captureMaterializedLocks(Stack, E);
  };
  // NOTE: every callback is a named local (not a temporary) so each outlives C
  // — function_ref does not own its callable; a temporary would dangle after
  // the `C{...};` statement (see the matching note in materializeAt).
  DenseSet<jeandle::ObjectID> &MatSet = MaterializedAtPred[PH][TargetMerge];
  Value *LogicalEscape = TargetMerge
                             ? static_cast<Value *>(TargetMerge)
                             : static_cast<Value *>(PH->getTerminator());
  MaterializeContext C{ExitInfo.FieldStates,
                       ExitInfo.FieldDefinitions,
                       ExitInfo.LockCounts,
                       ExitInfo.LiveLockEnters,
                       MatSet,
                       Reason,
                       LogicalEscape,
                       PH,
                       EdgeLocal ? TargetMerge : nullptr,
                       Recurse,
                       ClearLockState,
                       CaptureLocksIntoEffect,
                       ComputeSafeIP,
                       FlipState};
  ensureMaterialized(ID, C);
  // A block-end drain (!EdgeLocal) whose insertion point is a block-ending
  // invoke runs every replay side effect — field stores, lock re-emit, and
  // real-object exposure — on BOTH the normal and unwind edges, so the unwind
  // snapshot already stashed for that invoke (BlockExits[PH].UnwindData) must
  // also reflect this VO materialized with its locks cleared. Otherwise the
  // unwind successor observes a still-virtual VO and either re-emits the same
  // locks (double acquire) or drops the matching exit (leak). This mirrors the
  // location-based patch on the live per-block walk in processBlock, where
  // every MaterializeEffect whose InsertBefore == the block's invoke terminator
  // patches PreInvokeSnapshot; cascade members recurse through this function
  // and are covered individually. An edge-local (incoming-edge) materialize
  // splits the edge and does not execute at the invoke, so it needs no
  // unwind-snapshot patch.
  //
  // The guard below is defensive by construction: both !EdgeLocal callers pass
  // a loop preheader, whose single successor cannot terminate in an invoke
  // (asserted at the callers), so the branch is unreachable for them. It is
  // kept general so any future non-preheader block-end drain stays correct.
  if (!EdgeLocal && isa<InvokeInst>(PH->getTerminator())) {
    auto BEIt = BlockExits.find(PH);
    if (BEIt != BlockExits.end() && BEIt->second.UnwindData)
      markObjectMaterializedInExitData(*BEIt->second.UnwindData, ID,
                                       realIdentityOf(ID));
  }
}

// ===========================================================================
// Real loop fixpoint
// ===========================================================================
//
// Loop fixpoint driver. Loops without a unique preheader take a sound
// fallback (every forward-predecessor virtual is marked ineligible, the body
// runs once in Regular mode). Otherwise the driver manages mode escalation,
// the snapshot, and an outer retry loop wrapping the inner B/B' fixpoint:
//
//  - Mode escalation at the top-level (depth==1) entry: if the nest's max loop
//    depth exceeds JeandlePEALoopCutoff, the whole nest enters
//    Mode::StopNewInLoopNest (processAllocation refuses NEW allocations); a
//    test knob can force Mode::MaterializeAll for lit coverage. Nested entries
//    short-circuit on an in-progress overflow.
//  - Snapshot: takeLoopSnapshot captures the pre-loop analyzer state once; the
//    inner fixpoint and the MaterializeAll retry both restore from it.
//  - Outer retry loop wraps the inner B/B' fixpoint. The inner fixpoint runs
//    up to JeandlePEALoopFixpointMaxIters body passes via
//    processLoopBodyOnePass. The fixpoint state B starts as the preheader
//    state A; after each body pass, mergeStates(Header) computes
//    B' = merge(A, fresh latch states), and convergence compares B' with B via
//    exitDataEquivalent. Loop-end liveness is checked for monotonicity (a live
//    end must not become dead). Field PHIs inside the loop remain stable
//    across passes (same Value*) for B/B' structural equivalence through
//    LoopFieldPhiCache / OwnedLoopFieldPhis.
//
// On non-convergence OR overflow, a depth>1 (nested) loop propagates the
// overflow up without local recovery so the outermost (depth==1) loop owns the
// rollback + MaterializeAll redo of the whole nest. The depth==1 loop
// escalates to MaterializeAll ONCE (restoring the snapshot, wiping loop-block
// BlockExits, and draining preheader virtuals via
// processStateBeforeLoopOnOverflow so the redo starts with no live virtuals on
// entry). TooManyIterationsSeen is LOCAL per processLoop; a second failure
// hard-bails by marking every still-virtual loop VO ineligible so the original
// IR survives unchanged.

// Equality on BlockExitData (the per-object base data). Two payloads are
// equivalent iff every per-object dimension (still-virtual set, materialized
// set, FieldStates per offset, LockCounts, LiveLockEnters) matches by
// structural comparison.
bool Analyzer::exitDataEquivalent(const BlockExitData &A,
                                  const BlockExitData &B) {
  if (A.Virtuals.size() != B.Virtuals.size())
    return false;
  for (auto ID : A.Virtuals)
    if (!B.Virtuals.count(ID))
      return false;
  if (A.Materialized.size() != B.Materialized.size())
    return false;
  for (auto ID : A.Materialized)
    if (!B.Materialized.count(ID))
      return false;
  if (A.FieldStates.size() != B.FieldStates.size())
    return false;
  for (auto &Kv : A.FieldStates) {
    auto It = B.FieldStates.find(Kv.first);
    if (It == B.FieldStates.end())
      return false;
    if (Kv.second.size() != It->second.size())
      return false;
    for (auto &Off : Kv.second) {
      auto OIt = It->second.find(Off.first);
      if (OIt == It->second.end())
        return false;
      if (!Off.second.shallowEquals(OIt->second))
        return false;
    }
  }
  if (A.FieldDefinitions.size() != B.FieldDefinitions.size())
    return false;
  for (const auto &Kv : A.FieldDefinitions) {
    auto It = B.FieldDefinitions.find(Kv.first);
    if (It == B.FieldDefinitions.end() || Kv.second.size() != It->second.size())
      return false;
    for (const auto &Off : Kv.second) {
      auto OIt = It->second.find(Off.first);
      if (OIt == It->second.end() || Off.second.size() != OIt->second.size())
        return false;
      for (StoreInst *Def : Off.second)
        if (!OIt->second.count(Def))
          return false;
    }
  }
  if (A.LockCounts.size() != B.LockCounts.size())
    return false;
  for (auto &Kv : A.LockCounts) {
    auto It = B.LockCounts.find(Kv.first);
    if (It == B.LockCounts.end() || It->second != Kv.second)
      return false;
  }
  if (A.LiveLockEnters.size() != B.LiveLockEnters.size())
    return false;
  for (auto &Kv : A.LiveLockEnters) {
    auto It = B.LiveLockEnters.find(Kv.first);
    if (It == B.LiveLockEnters.end())
      return false;
    if (Kv.second.size() != It->second.size())
      return false;
    for (size_t i = 0, e = Kv.second.size(); i != e; ++i)
      // Loop fixpoint convergence compares call-site identity. The independent
      // CFG dataflow assigns each call site one stable BytecodeDepth.
      if (Kv.second[i].Call != It->second[i].Call)
        return false;
  }
  return true;
}

// Captures the pre-loop analyzer state into S: the current per-block state,
// the alias map snapshot, field/lock/virtual ledgers, the eligibility map, and
// the OwnedPhis/OwnedInsts/CFG-proof truncation watermarks. Also clones the
// per-loop-block (and preheader) BlockEffects and MaterializedAtPred ledgers so
// a Full or Iteration restore can reinstate them exactly. The preheader is
// snapshotted separately because it is not part of LoopBlocks.
void Analyzer::takeLoopSnapshot(
    Loop *L, const llvm::SmallPtrSetImpl<BasicBlock *> &LoopBlocks,
    LoopSnapshot &S) {
  S.Preheader = L->getLoopPreheader();
  S.CurrentState = CurrentState;
  S.Aliases = Aliases.snapshot();
  S.FieldStates = FieldStates;
  S.FieldDefinitions = FieldDefinitions;
  S.ObservedFieldStores = ObservedFieldStores;
  S.VirtualRefStoreTargets = VirtualRefStoreTargets;
  S.LockCounts = LockCounts;
  S.LiveLockEnters = LiveLockEnters;
  S.Materialized = Materialized;
  S.EligibleSnapshot = Eligible;
  S.PreIterVOCount = Result.VirtualObjects.size();
  S.OwnedPhisSize = Result.OwnedPhis.size();
  S.OwnedInstsSize = Result.OwnedInsts.size();
  S.CFGDeadnessProofCount = CFGDeadnessProofs.size();
  S.NeedsCFGCleanup = Result.NeedsCFGCleanup;
  S.SavedBlockEffects.clear();
  S.SavedMaterializedAtPred.clear();
  S.HadBlockEffects.clear();
  S.HadMaterializedAtPred.clear();
  auto SaveBlockLedgers = [&](BasicBlock *BB) {
    auto FIt = Result.BlockEffects.find(BB);
    if (FIt != Result.BlockEffects.end()) {
      S.HadBlockEffects.insert(BB);
      S.SavedBlockEffects[BB] = FIt->second.clone();
    }
    auto MIt = MaterializedAtPred.find(BB);
    if (MIt != MaterializedAtPred.end()) {
      S.HadMaterializedAtPred.insert(BB);
      S.SavedMaterializedAtPred[BB] = MIt->second;
    }
  };
  for (BasicBlock *BB : LoopBlocks)
    SaveBlockLedgers(BB);
  if (S.Preheader) {
    assert(!LoopBlocks.count(S.Preheader) &&
           "a loop cannot contain its canonical preheader");
    SaveBlockLedgers(S.Preheader);
  }
}

#ifndef NDEBUG
void Analyzer::assertPreservedLoopSeedDoesNotReferenceTruncatedOwnedValues(
    const BlockExitData &Seed, const LoopSnapshot &S) const {
  SmallPtrSet<Value *, 16> ToDelete;
  for (size_t I = S.OwnedPhisSize; I < Result.OwnedPhis.size(); ++I)
    if (Value *V = Result.OwnedPhis[I])
      ToDelete.insert(V);
  for (size_t I = S.OwnedInstsSize; I < Result.OwnedInsts.size(); ++I)
    if (Value *V = Result.OwnedInsts[I])
      ToDelete.insert(V);

  for (const auto &ObjectFields : Seed.FieldStates)
    for (const auto &Field : ObjectFields.second) {
      const jeandle::FieldValue &Value = Field.second;
      if (Value.isScalar())
        assert(!ToDelete.count(Value.getScalar()) &&
               "preserved loop seed references an OwnedPhi/OwnedInst that "
               "iteration restore will delete");
      if (Value.isMaterializedRef())
        assert(!ToDelete.count(Value.getMaterialized()) &&
               "preserved loop seed references an OwnedPhi/OwnedInst that "
               "iteration restore will delete");
    }
}
#endif

// Restores analyzer state from a LoopSnapshot. Iteration mode (inner fixpoint
// retry) preserves the alias map and the preheader's edge-local materialization
// together with B, and truncates only the loop-block ledgers plus
// OwnedPhis/OwnedInsts created since the snapshot, the CFG proof ledger, and
// per-block BlockEffects/MaterializedAtPred. Full mode (MaterializeAll retry)
// also restores the alias map and the preheader's pre-attempt effects/ledger.
// OwnedLoopFieldPhis are deliberately NOT truncated: their stable identity
// across iterations is what lets B/B' structural equivalence converge.
void Analyzer::restoreLoopSnapshot(
    const llvm::SmallPtrSetImpl<BasicBlock *> &LoopBlocks,
    const LoopSnapshot &S, LoopRestoreMode Mode,
    const BlockExitData *PreservedSeed) {
  CurrentState = S.CurrentState;
  // Iteration restore keeps the closure-global alias map: the preceding header
  // merge's PHI alias is the next B traversal's input. Full recovery returns to
  // the pre-loop attempt and restores the whole map.
  if (Mode == LoopRestoreMode::Full)
    Aliases.restore(S.Aliases);
  FieldStates = S.FieldStates;
  FieldDefinitions = S.FieldDefinitions;
  ObservedFieldStores = S.ObservedFieldStores;
  VirtualRefStoreTargets = S.VirtualRefStoreTargets;
  LockCounts = S.LockCounts;
  LiveLockEnters = S.LiveLockEnters;
  Materialized = S.Materialized;
  Eligible = S.EligibleSnapshot;

  // Allocation-site cache entries outlive traversal rollback. Restore their
  // default eligibility so the same static site can represent a new dynamic
  // object on the next traversal.
  for (size_t I = S.PreIterVOCount, E = Result.VirtualObjects.size(); I < E;
       ++I) {
    if (!Result.VirtualObjects[I])
      continue;
    Eligible[Result.VirtualObjects[I]->getID()] = true;
  }

#ifndef NDEBUG
  if (Mode == LoopRestoreMode::Iteration) {
    assert(PreservedSeed && "iteration restore requires its preserved B seed");
    assertPreservedLoopSeedDoesNotReferenceTruncatedOwnedValues(*PreservedSeed,
                                                                S);
  } else {
    assert(!PreservedSeed && "Full restore abandons rather than preserves B");
  }
#else
  (void)PreservedSeed;
#endif

  // Pop and delete unparented PHIs / insts created during the rolled-back
  // iteration. OwnedLoopFieldPhis are NOT touched — they're the per-loop
  // PHI cache, and the whole point of the cache is to keep them alive
  // across iterations. The truncation logic is shared with deleteOwnedSince
  // via PEAResult::truncateOwnedTo.
  Result.truncateOwnedTo(S.OwnedPhisSize, S.OwnedInstsSize);
  CFGDeadnessProofs.resize(S.CFGDeadnessProofCount);
  Result.NeedsCFGCleanup = S.NeedsCFGCleanup;
  RecordedCFGProofs.clear();
  for (const CFGDeadnessProof &Proof : CFGDeadnessProofs)
    RecordedCFGProofs.insert(Proof.Killer);

  // Roll back failed traversal effects and block-local ledgers. An ordinary
  // retry restores only LoopBlocks, preserving the preheader's edge-local
  // materialization together with B. Full recovery also restores the exact
  // pre-attempt preheader effects and ledger before its block-end drain.
  // Pending queues contain traversal-local effect objects and never survive
  // a loop-block restore; stable PHI and synthetic-VO shells live in their
  // dedicated analyzer caches.
  auto RestoreBlockLedgers = [&](BasicBlock *BB, bool ClearTraversalQueues) {
    auto SF = S.SavedBlockEffects.find(BB);
    if (S.HadBlockEffects.count(BB))
      Result.BlockEffects[BB] = SF->second.clone();
    else
      Result.BlockEffects.erase(BB);

    auto SM = S.SavedMaterializedAtPred.find(BB);
    if (S.HadMaterializedAtPred.count(BB))
      MaterializedAtPred[BB] = SM->second;
    else
      MaterializedAtPred.erase(BB);

    if (ClearTraversalQueues) {
      PendingMergePhis.erase(BB);
      PendingMaterializeAllVOs.erase(BB);
    }
  };
  for (BasicBlock *BB : LoopBlocks)
    RestoreBlockLedgers(BB, /*ClearTraversalQueues=*/true);
  if (Mode == LoopRestoreMode::Full && S.Preheader)
    RestoreBlockLedgers(S.Preheader, /*ClearTraversalQueues=*/false);
  // Restoring the per-block EffectLists changes the effect set.
  ++Result.EffectEpoch;
}

SmallVector<BasicBlock *, 32>
Analyzer::loopBlocksInRPO(Loop *L, ArrayRef<BasicBlock *> FunctionRPO) {
  // Function-RPO filtered to L's blocks. FunctionRPO is computed once by
  // Analyzer::run and reused by every loop in the function.
  SmallVector<BasicBlock *, 32> Order;
  for (BasicBlock *BB : FunctionRPO)
    if (L->contains(BB))
      Order.push_back(BB);
  return Order;
}

void Analyzer::processLoopBodyOnePass(Loop *L, ArrayRef<BasicBlock *> LoopRPO,
                                      ArrayRef<BasicBlock *> FunctionRPO,
                                      const BlockExitData *HeaderSeed) {
  // Process loop blocks in function-RPO order. Sub-loop headers dispatch
  // recursively to processLoop, and the sub-loop's blocks are marked Done so
  // we don't re-process them in this pass. FunctionRPO is computed once by
  // Analyzer::run; LoopRPO is the filtered loop-local view reused across the
  // inner fixpoint iterations.
  //
  // Publish the active body pass (loop + blocks processed so far) so
  // processBlockPhis can tell a loop-header PHI's not-yet-processed
  // back-edge predecessor (unknown) from a genuinely non-virtual incoming
  // (divergence). Stack semantics for the nested processLoop recursion
  // below; restored on every exit, including the OverflowFlag early
  // returns, so the post-body merge (which runs after this function
  // returns) and any outer loop see their own context.
  Loop *SavedBodyPassLoop = ActiveBodyPassLoop;
  llvm::SmallPtrSet<BasicBlock *, 16> SavedBodyPassProcessed;
  SavedBodyPassProcessed.swap(BodyPassProcessed);
  ActiveBodyPassLoop = L;
  auto RestoreBodyPass = llvm::make_scope_exit([&] {
    ActiveBodyPassLoop = SavedBodyPassLoop;
    BodyPassProcessed.swap(SavedBodyPassProcessed);
  });
  for (BasicBlock *BB : LoopRPO) {
    if (BodyPassProcessed.count(BB))
      continue;
    Loop *Inner = LI.getLoopFor(BB);
    if (Inner && Inner != L && Inner->getHeader() == BB) {
      // Found a sub-loop's header — recurse.
      processLoop(Inner, FunctionRPO);
      // A nested loop failure stops this traversal immediately. Overflow is
      // recovered by the outermost loop; loop-end invariant failures discard
      // the complete analysis attempt.
      if (OverflowFlag || InvalidLoopMonotonicity ||
          !RetryVirtualizationAllocationSites.empty())
        return;
      for (BasicBlock *SB : Inner->blocks())
        BodyPassProcessed.insert(SB);
      continue;
    }
    if (BB == L->getHeader() && HeaderSeed)
      processSeededLoopHeader(BB, *HeaderSeed);
    else
      processBlock(BB);
    // Defensive polling keeps future block handlers from extending a
    // half-built traversal after either attempt-local failure mode.
    if (OverflowFlag || InvalidLoopMonotonicity ||
        !RetryVirtualizationAllocationSites.empty())
      return;
    BodyPassProcessed.insert(BB);
  }
}

// Loop fixpoint driver. The section banner above ("Real loop fixpoint")
// describes the overall structure: no-preheader fallback, mode escalation,
// snapshot, outer retry loop wrapping the inner B/B' fixpoint, and the
// overflow / second-failure propagation rules.
void Analyzer::processLoop(Loop *L, ArrayRef<BasicBlock *> FunctionRPO) {
  // Record EVERY processLoop entry (including for loops with no
  // header / no preheader / OverflowFlag short-circuit) so the safety-net
  // pass treats this loop as visited and skips it.
  VisitedLoops.insert(L);
  BasicBlock *Preheader = L->getLoopPreheader();
  BasicBlock *Header = L->getHeader();
  if (!Header) {
    // Defensive: a loop with no header would be malformed LoopInfo state.
    return;
  }
  if (InvalidLoopMonotonicity || !RetryVirtualizationAllocationSites.empty())
    return;
  if (!Preheader) {
    // Loop without a unique preheader. Jeandle schedules LoopSimplifyPass
    // before PEA, so natural reducible-CFG loops reach the fixpoint path
    // above; we land here only for cases LoopSimplify cannot canonicalise —
    // indirectbr-entered loops and genuinely irreducible cycles LoopInfo
    // still recognises as a natural loop with multiple entry edges.
    //
    // "Materialize at every forward predecessor" is not implementable in our
    // effects model: each Materialize records OrigAlloc (reused) as its
    // replay receiver in MaterializedReceiverOf. OrigAlloc is the single
    // dominating def on every edge (the existing Case-A pattern works only
    // because an explicit PHI already exists).
    //
    // Sound fallback: mark every VO still virtual at any forward predecessor
    // INELIGIBLE. commit() drops its effects and the original IR survives
    // unchanged — the body's pre-loop pointer is the original OrigAlloc on
    // every entry edge, which trivially dominates the body. Loop-local
    // allocs (created and consumed within a single iteration) are still
    // candidates: the body walk below runs once in REGULAR mode. They are
    // never virtual at any forward pred (forward preds are outside L), so the
    // sweep above doesn't touch them, and the missing fixpoint is irrelevant
    // because they don't cross the back-edge.

    // Collect forward (non-loop-back) predecessors of the header.
    llvm::SmallVector<BasicBlock *, 4> ForwardPreds;
    llvm::SmallPtrSet<BasicBlock *, 4> Seen;
    for (BasicBlock *P : predecessors(Header)) {
      if (L->contains(P))
        continue;
      if (Seen.insert(P).second)
        ForwardPreds.push_back(P);
    }

    // Bail every VO that is virtual at any forward pred — drop it back to the
    // original IR. BlockExits[P] is populated by the outer RPO walk (forward
    // preds are processed before processLoop is invoked on L).
    for (BasicBlock *P : ForwardPreds) {
      auto It = BlockExits.find(P);
      if (It == BlockExits.end())
        continue;
      BlockExitInfo &PExit = It->second;
      for (jeandle::ObjectID ID : PExit.Virtuals) {
        observeFieldDefinitions(ID, PExit.FieldDefinitions);
        markIneligible(ID, /*FreshRetry=*/true);
      }
    }
    if (!RetryVirtualizationAllocationSites.empty())
      return;

    // Body walk in REGULAR mode (single pass — no fixpoint, since there is
    // no way to verify convergence at a non-existent preheader). Loop-local
    // allocs that don't outlive a single iteration are still virtualised.
    processLoopBodyOnePass(L, loopBlocksInRPO(L, FunctionRPO), FunctionRPO);
    if (InvalidLoopMonotonicity || !RetryVirtualizationAllocationSites.empty())
      return;

    // Post-body merge. The in-pass header merge (header first in RPO) runs
    // before any loop-body alloc is virtualized, so it cannot resolve an object
    // allocated INSIDE the loop and carried across the back-edge via a header
    // pointer-phi — the back-edge slot is nullopt and the PHI is skipped,
    // which would misclassify the alloc NeverEscapes and RAUW it to poison.
    // Re-running mergeStates(Header) now that the latch BlockExits is populated
    // lets processBlockPhis Case A fire and materialize such a carried object
    // at the back-edge pred's terminator, matching the fixpoint path's
    // post-body merge. This is a one-shot merge (no convergence loop here), so
    // its effects simply persist to commit().
    resetPerBlockState();
    mergeStates(Header);
    if (!RetryVirtualizationAllocationSites.empty())
      return;
    // Drain the merge's deferred CreatePHI effects the same way the fixpoint
    // path's post-body merge does: a one-shot post-body Case C (or a field
    // merge) needs them to reach transform; clearing them here would leave
    // the header PHI aliased to a synthetic whose field PHIs never get
    // inserted.
    drainPendingMergePhis(Header);

    // OverflowFlag is deliberately NOT cleared here: if processLoopBodyOnePass
    // latched it (a nested loop overflowed), it propagates conservatively up so
    // any enclosing loop context also bails. Every loop entry polls it
    // (depth==1 clears it, a nested entry short-circuits on it), so a stale
    // flag can only make us more conservative, never unsound.
    return;
  }

  llvm::SmallPtrSet<BasicBlock *, 8> LoopBlocks;
  for (BasicBlock *BB : L->blocks())
    LoopBlocks.insert(BB);

  // ReentrantBlockIterator numbers loop ends by the loop header's structural
  // predecessor order. Preserve that order for every outer attempt.
  SmallVector<BasicBlock *, 4> LoopEnds;
  for (BasicBlock *Pred : predecessors(Header))
    if (L->contains(Pred))
      LoopEnds.push_back(Pred);

  // Loop blocks in function-RPO order, computed once and reused across the
  // inner fixpoint body passes below (the loop CFG is stable across PEA).
  SmallVector<BasicBlock *, 32> LoopRPO = loopBlocksInRPO(L, FunctionRPO);

  // At TOP-LEVEL processLoop entry only (loop.getDepth() == 1 gate),
  // compute the maximum loop depth within this nest. If it exceeds
  // JeandlePEALoopCutoff, transiently enter Mode::StopNewInLoopNest for
  // the duration of the fixpoint: processAllocation refuses NEW allocations,
  // but everything else (already-virtual tracking, merges, locks, loads,
  // stores, loop-exit handling) proceeds normally. The mode is restored
  // at the bottom of this function on convergence at depth==1.
  const Mode SavedModeForNest = CurrentMode;
  if (L->getLoopDepth() == 1) {
    // Count one outer-fixpoint entry per top-level processLoop call.
    ++AttemptStats.OuterFixpointIterations;

    // Mode::StopNewInLoopNest suppresses new virtualizations in deep nests.
    // Jeandle sets it nest-wide at the outermost loop when the nest's max depth
    // exceeds the cutoff — a conservative choice (shallower loops in the nest
    // also run StopNew, but StopNew only suppresses NEW virtualizations, which
    // is harmless since already-virtual tracking, merges, locks, loads, stores,
    // and loop-exit handling all proceed normally).
    unsigned MaxDepth = L->getLoopDepth();
    for (Loop *Sub : L->getLoopsInPreorder())
      MaxDepth = std::max(MaxDepth, Sub->getLoopDepth());
    if (CurrentMode == Mode::Regular && MaxDepth > JeandlePEALoopCutoff)
      CurrentMode = Mode::StopNewInLoopNest;

    // Testing aid: optionally force MATERIALIZE_ALL for lit coverage.
    if (JeandlePEAForceMaterializeAll) {
      CurrentMode = Mode::MaterializeAll;
      ++AttemptStats.ModeEscalations;
    }

    // Overflow recovery is scoped to one nest: clear the cross-recursion
    // signal on every top-level entry.
    OverflowFlag = false;
  } else {
    // Nested-loop entry: bail immediately if an outer overflow is already in
    // progress. Overflow recovery is owned by the outermost (depth==1) loop,
    // so a nested entry must not run its own fixpoint against a half-consistent
    // outer state.
    if (OverflowFlag)
      return;
  }

  // Snapshot pre-loop state once. The inner fixpoint and the MaterializeAll
  // retry both restore from it. Convergence is BlockExits-based, so each loop
  // level needs its own rollback record.
  LoopSnapshot Pre;
  takeLoopSnapshot(L, LoopBlocks, Pre);

  // Outer retry loop: run the Regular inner fixpoint; on non-convergence OR
  // overflow escalate to MaterializeAll once and retry the whole fixpoint; a
  // second failure hard-bails. TooManyIterationsSeen is LOCAL to each
  // processLoop, so each loop gets one independent escalation.
  bool TooManyIterationsSeen = false;
  while (true) {
    SmallBitVector KnownAliveLoopEnds(LoopEnds.size(), false);

    // Each outer attempt starts at the current forward-edge state A. The
    // pointer-PHI aliases are initialized from that edge exactly once, then
    // every inner traversal consumes B directly. A nested processLoop owns an
    // independent pair of stack-local B/B' states.
    std::optional<BlockExitData> ForwardState;
    {
      ScopedEdgeExitViews EdgeViews(*this);
      EdgeContribution Forward = contributionFor(Preheader, Header);
      if (Forward.isLive())
        ForwardState = *Forward.Data;
    }
    if (!ForwardState) {
      // B is a live abstract state. A dead or not-yet-published forward edge
      // must use the ordinary structural entry gate instead of being promoted
      // into a seeded live traversal.
      for (BasicBlock *BB : LoopBlocks)
        BlockExits.erase(BB);
      processLoopBodyOnePass(L, LoopRPO, FunctionRPO);
      if (L->getLoopDepth() == 1)
        CurrentMode = SavedModeForNest;
      return;
    }
    BlockExitData LastMergedState = std::move(*ForwardState);
    BlockExitData NewMergedState;
    initializeLoopHeaderPhiAliases(Header, Preheader);

    // ---- inner fixpoint: up to JeandlePEALoopFixpointMaxIters body passes
    // Single-state B convergence. B is the header's merged state (seeded := A,
    // the preheader exit). Each pass runs the body, then a post-body merge
    // computes B' = merge(A, fresh latch exits); converge when B' == B.
    // Because the post-body merge sees iteration 0's latch exits, the loop can
    // converge in a single body pass.
    bool Converged = false;
    for (unsigned Iter = 0; Iter < JeandlePEALoopFixpointMaxIters; ++Iter) {
      if (Iter > 0)
        restoreLoopSnapshot(LoopBlocks, Pre, LoopRestoreMode::Iteration,
                            &LastMergedState);
      // Each pass starts from a fresh end-state map. B is the only cross-pass
      // header input; old loop/nested-loop edge payloads must not participate,
      // including on iteration zero.
      for (BasicBlock *BB : LoopBlocks)
        BlockExits.erase(BB);
      ++AttemptStats.LoopFixpointRetries;

      processLoopBodyOnePass(L, LoopRPO, FunctionRPO, &LastMergedState);

      if (!RetryVirtualizationAllocationSites.empty()) {
        if (L->getLoopDepth() == 1)
          CurrentMode = SavedModeForNest;
        return;
      }

      // Overflow (a STOP_NEW materialization of an outer-scope VO) may have
      // been latched by this pass or a deeper recursion. Stop iterating: the
      // state is half-consistent and is rolled back below.
      if (OverflowFlag || InvalidLoopMonotonicity)
        break;

      // A completed traversal returns one state for every structural loop end.
      // Snapshot the fresh edge contributions before the post-body header merge
      // mutates any edge-local view.
      SmallVector<EdgeContributionKind, 4> LoopEndKinds;
      {
        ScopedEdgeExitViews EdgeViews(*this);
        for (BasicBlock *LoopEnd : LoopEnds) {
          EdgeContribution Contribution = contributionFor(LoopEnd, Header);
          if (Contribution.isUnseen()) {
            InvalidLoopMonotonicity = true;
            LLVM_DEBUG({
              dbgs() << "PEA: loop traversal incomplete at ";
              Header->printAsOperand(dbgs(), false);
              dbgs() << ": backedge ";
              LoopEnd->printAsOperand(dbgs(), false);
              dbgs() << " did not publish an exit state\n";
            });
            break;
          }
          LLVM_DEBUG({
            dbgs() << "PEA: loop @ " << Header->getName() << " iteration "
                   << (Iter + 1) << " backedge ";
            LoopEnd->printAsOperand(dbgs(), false);
            dbgs() << " is " << (Contribution.isLive() ? "live" : "dead")
                   << "\n";
          });
          LoopEndKinds.push_back(Contribution.Kind);
        }
      }
      if (InvalidLoopMonotonicity)
        break;

      // Post-body merge: compute the true B' = merge(A, fresh latch end-states)
      // after the body pass. The seeded header deliberately skips
      // predecessor/PHI merging, so this is the one structural header merge for
      // the traversal and iteration zero can already compare a complete B' with
      // B.
      //
      // This merge runs after the body, so it is the only place that can
      // resolve an object allocated INSIDE the loop body and carried across the
      // back-edge via a header pointer-phi. Here the latch BlockExits is
      // populated and the allocation alias is known, so processBlockPhis Case A
      // fires and materializes the carried object at the back-edge pred's
      // terminator.
      //
      // The merge's effects are KEPT on convergence — no snapshot/restore
      // discard. A non-converged iteration's effects are cleared by the next
      // iteration's restoreLoopSnapshot(Pre) at the top of the loop (it
      // restores per-loop-block BlockEffects/MaterializedAtPred). The per-pred
      // materialized state is stable across iterations (MaterializedAtPred is
      // snapshotted+restored via LoopSnapshot, and under reuse-OrigAlloc the
      // materialized value is OrigAlloc on every edge), so B' is stable and
      // the fixpoint converges rather than escalating to MaterializeAll.
      // PendingMergePhis[Header] is drained so the converged post-body Case C
      // or field merge reaches the transform. Failed-pass effect objects are
      // removed by Iteration restore; their cached PHI shells remain stable.
      {
        resetPerBlockState();
        mergeStates(Header);
        NewMergedState = BlockExitData();
        snapshotExitStateInto(NewMergedState); // B'
        drainPendingMergePhis(Header);
      }
      if (!RetryVirtualizationAllocationSites.empty()) {
        if (L->getLoopDepth() == 1)
          CurrentMode = SavedModeForNest;
        return;
      }
      // B' vs B convergence check. No iteration gate: with the post-body merge,
      // iteration 0 already has a true B' to compare against B := A.
      if (exitDataEquivalent(LastMergedState, NewMergedState)) {
        Converged = true;
        LLVM_DEBUG(dbgs() << "PEA: loop @ " << Header->getName()
                          << " converged in " << (Iter + 1)
                          << " iters (B-based, post-body)\n");
        break;
      }

      // Update knownAliveLoopEnds only after a completed non-converged pass. A
      // live end may stay live, and a previously dead end may become live as B
      // grows less precise, but live must not become dead.
      for (unsigned I = 0; I != LoopEndKinds.size(); ++I) {
        const bool IsLive = LoopEndKinds[I] == EdgeContributionKind::Live;
        if (KnownAliveLoopEnds[I] &&
            LoopEndKinds[I] == EdgeContributionKind::Dead) {
          InvalidLoopMonotonicity = true;
          LLVM_DEBUG({
            dbgs() << "PEA: loop-end liveness monotonicity violation at ";
            Header->printAsOperand(dbgs(), false);
            dbgs() << ": backedge ";
            LoopEnds[I]->printAsOperand(dbgs(), false);
            dbgs() << " changed from live to dead\n";
          });
          break;
        }
        KnownAliveLoopEnds[I] = KnownAliveLoopEnds[I] || IsLive;
      }
      if (InvalidLoopMonotonicity)
        break;

      LLVM_DEBUG(dbgs() << "PEA: loop @ " << Header->getName()
                        << " retry after " << (Iter + 1)
                        << " iters (B != B')\n");
      LastMergedState = NewMergedState; // B := B'
    }

    if (InvalidLoopMonotonicity) {
      if (L->getLoopDepth() == 1)
        CurrentMode = SavedModeForNest;
      return;
    }

    if (Converged) {
      // On convergence at depth==1, restore the saved (pre-nest) mode so the
      // escalation does not leak past this nest. Nested loops leave the mode
      // as-is so an escalation persists through the rest of the nest.
      if (L->getLoopDepth() == 1)
        CurrentMode = SavedModeForNest;
      return;
    }

    LLVM_DEBUG(dbgs() << "PEA: loop @ " << Header->getName()
                      << " did not converge; "
                      << (OverflowFlag ? "overflow" : "iteration cap") << "\n");

    // Not converged: non-convergence (iteration cap) OR overflow.
    if (OverflowFlag && L->getLoopDepth() > 1) {
      // A nested loop propagates the overflow up without local recovery: the
      // outermost (depth==1) loop owns the rollback + MaterializeAll redo of
      // the whole nest.
      return;
    }

    if (!TooManyIterationsSeen) {
      // First exhaustion/overflow: escalate to MaterializeAll and retry the
      // whole fixpoint.
      TooManyIterationsSeen = true;
      if (CurrentMode != Mode::MaterializeAll)
        ++AttemptStats.ModeEscalations;
      restoreLoopSnapshot(LoopBlocks, Pre, LoopRestoreMode::Full);
      for (BasicBlock *BB : LoopBlocks)
        BlockExits.erase(BB);
      // Consume the overflow signal and leave STOP_NEW before draining.
      // ensureMaterialized and synthetic-DAG preparation both poll these
      // controls, so changing them afterward would make the explicit drain a
      // no-op and defer the same work to a later header merge.
      CurrentMode = Mode::MaterializeAll;
      OverflowFlag = false;
      // Drain every still-virtual VO at the loop's forward end so the redo
      // starts with no live virtuals on entry.
      processStateBeforeLoopOnOverflow(L);
      if (!RetryVirtualizationAllocationSites.empty()) {
        if (L->getLoopDepth() == 1)
          CurrentMode = SavedModeForNest;
        return;
      }
      // The next outer attempt recomputes A/B after the preheader drain and
      // reinitializes the header pointer-PHI aliases from that forward edge.
      continue;
    }

    // Second exhaustion: hard fail. MaterializeAll is expected to always
    // converge, so this indicates a pathological-IR / invariant gap; fall back
    // SOUNDLY by marking every still-virtual VO in the loop ineligible (the
    // original IR then survives unchanged — a conservative fallback).
    LLVM_DEBUG(dbgs() << "PEA: loop @ " << Header->getName()
                      << " did NOT converge in MATERIALIZE_ALL; sound bail\n");
    for (BasicBlock *BB : LoopBlocks) {
      auto EIt = BlockExits.find(BB);
      if (EIt == BlockExits.end())
        continue;
      for (jeandle::ObjectID ID : EIt->second.Virtuals) {
        observeFieldDefinitions(ID, EIt->second.FieldDefinitions);
        markIneligible(ID);
      }
    }
    if (L->getLoopDepth() == 1)
      CurrentMode = SavedModeForNest;
    // OverflowFlag is deliberately NOT cleared here: like the no-preheader
    // path, a stale flag propagates conservatively up so any enclosing loop
    // context also bails (every loop entry polls it). This hard-bail already
    // marked every loop virtual ineligible, so the original IR survives.
    return;
  }
}

// Single fresh-attempt analysis pass over F. Walks the function in RPO,
// dispatching top-level loops to processLoop (which recursively handles
// sub-loops) and processing other blocks directly, with a defensive sweep for
// back-edges LoopInfo missed. After the walk: drains preheader virtuals for
// any unvisited loops, commits the effect plan, then runs the post-commit
// validateFinalDeoptObligations and validateCFGDeadnessProofs audits. Any
// structural, deopt, or materialization failure sets
// RetryVirtualizationAllocationSites / InvalidDeoptObligation /
// InvalidCFGProofKillers and returns an empty result so the outer fresh-retry
// loop in PartialEscapeAnalysis::run can suppress the offending sites and
// restart from untouched IR.
jeandle::PEAResult Analyzer::run() {
  if (JeandlePEALoopFixpointMaxIters == 0)
    report_fatal_error("-jeandle-pea-loop-fixpoint-max-iters must be at least "
                       "1");

  // Apply the legacy substring gate and the repeatable exact-name gate
  // independently. Empty filters preserve the existing all-functions
  // behavior.
  if (!JeandleEscapeAnalyzeOnly.empty() &&
      !F.getName().contains(JeandleEscapeAnalyzeOnly))
    return jeandle::PEAResult();
  if (!matchesExactAnalyzeFunction(F.getName()))
    return jeandle::PEAResult();

  // Outer walk: RPO over F. When we hit any block belonging to a top-level
  // loop, dispatch to processLoop on that top-level loop (which recursively
  // handles sub-loops). All other blocks are processed directly.
  llvm::SmallPtrSet<BasicBlock *, 16> Done;
  ReversePostOrderTraversal<Function *> RPOT(&F);
  SmallVector<BasicBlock *, 32> FunctionRPO;
  for (BasicBlock *BB : RPOT)
    FunctionRPO.push_back(BB);
  // Defensive sweep for cycles LoopInfo missed (indirectbr /
  // callbr / catchswitch back-edges). When the RPO walk reaches a non-
  // loop block whose preds include an as-yet-UNVISITED block, that
  // unvisited predecessor is a back-edge that LoopInfo did not
  // recognise. Without intervention, mergeStates would silently drop
  // the back-edge contribution (no exit data for it yet); the resulting
  // virtual state at BB would not reflect the cross-iteration field
  // mutations. Bail every still-virtual VO at BB entry to ineligibility
  // so the original IR survives unchanged.
  auto bailUnvisitedBackEdgeVOs = [&](BasicBlock *BB) {
    if (BB == &F.getEntryBlock())
      return;
    bool HasUnvisitedPred = false;
    for (BasicBlock *P : predecessors(BB)) {
      if (!Done.count(P)) {
        HasUnvisitedPred = true;
        break;
      }
    }
    if (!HasUnvisitedPred)
      return;
    // Conservative ineligibility flip on every VO that is currently
    // tracked as virtual in ANY processed pred's exit. Mirrors the
    // forward-pred sweep in the no-preheader fallback.
    for (BasicBlock *P : predecessors(BB)) {
      auto It = BlockExits.find(P);
      if (It == BlockExits.end())
        continue;
      for (jeandle::ObjectID ID : It->second.Virtuals) {
        observeFieldDefinitions(ID, It->second.FieldDefinitions);
        markIneligible(ID);
      }
    }
    BlockExits.erase(BB);
  };
  for (BasicBlock *BB : FunctionRPO) {
    if (Done.count(BB))
      continue;
    Loop *L = LI.getLoopFor(BB);
    if (!L) {
      bailUnvisitedBackEdgeVOs(BB);
      processBlock(BB);
      if (!RetryVirtualizationAllocationSites.empty())
        return jeandle::PEAResult();
      Done.insert(BB);
      continue;
    }
    // Find the top-level loop containing BB. Sub-loops are dispatched
    // recursively from inside processLoop on the top-level loop.
    Loop *Top = L;
    while (Top->getParentLoop())
      Top = Top->getParentLoop();
    // If we haven't reached the top-level header in RPO yet (e.g. when a
    // block inside the loop appears before its header), still dispatch on
    // the top-level loop and mark all its blocks Done.
    processLoop(Top, FunctionRPO);
    if (InvalidLoopMonotonicity || !RetryVirtualizationAllocationSites.empty())
      return jeandle::PEAResult();
    for (BasicBlock *SB : Top->blocks())
      Done.insert(SB);
  }

  if (InvalidLoopMonotonicity)
    return jeandle::PEAResult();

  // Safety net — drain preheader virtuals ONLY for loops the RPO
  // walk never reached (unreachable top-level loops, or sub-loops whose
  // outer recursion bailed before recursing). Everything else has been
  // handled by processLoop directly. Loops with no preheader are a no-op
  // either way (the function cannot pick a drain IP without a PH).
  materializePreheaderVirtualsForUnvisitedLoops();
  if (!RetryVirtualizationAllocationSites.empty())
    return jeandle::PEAResult();
  commit();
  if (!RetryVirtualizationAllocationSites.empty())
    return jeandle::PEAResult();
  validateFinalDeoptObligations();
  if (InvalidDeoptObligation)
    return jeandle::PEAResult();
  InvalidCFGProofKillers = validateCFGDeadnessProofs();
  if (!InvalidCFGProofKillers.empty())
    return jeandle::PEAResult();
  if (!Result.hasLegalMaterializationAtomicTypes(DL))
    return jeandle::PEAResult();
  publishAttemptOutputs();
  return std::move(Result);
}

} // anonymous namespace

// Outer fresh-retry driver. Runs the per-attempt Analyzer::run with
// monotonically growing suppression sets: SuppressedCFGProofs (for invalid CFG
// deadness proofs), SuppressedVirtualizations (for structural/materialization
// and final-deopt obligation failures). Each retry restarts from untouched IR
// with at least one newly suppressed stable site, so the fixpoint converges in
// a small number of retries; a retry that suppresses nothing new indicates an
// invariant failure and terminates conservatively.
PartialEscapeAnalysis::Result
PartialEscapeAnalysis::run(Function &F, FunctionAnalysisManager &FAM) {
  // Gate on jeandle.java_method_compilation: only Java methods are analyzed
  // (template module / runtime stubs are skipped).
  Module *M = F.getParent();
  if (!M || !M->getNamedMetadata(jeandle::Metadata::JavaMethodCompilation))
    return jeandle::PEAResult();

  // TODO(compressed-oop): PEA does not model narrow-oop (addrspace 3)
  // reference fields yet — skip the whole analysis when the module's
  // DataLayout describes a narrow-oop address space (the frontend appends
  // p3:32:32:32 only when CompressedOops are configured; without a p3 spec
  // getPointerSize(3) falls back to the default pointer size, equal to
  // addrspace(1), and PEA runs normally). This is the load-bearing gate that
  // keeps the DEFAULT VM configuration (compressed oops on) usable;
  // getOrCreateFieldIndex separately bails per-access on non-addrspace(1)
  // fields as defense in depth for hand-written / mixed IR.
  const DataLayout &DL = M->getDataLayout();
  if (DL.getPointerSize(jeandle::AddrSpace::NarrowOopAddrSpace) !=
      DL.getPointerSize(jeandle::AddrSpace::JavaHeapAddrSpace))
    return jeandle::PEAResult();

  // Request DominatorTree and LoopInfo eagerly so they're cached for later
  // PEA passes that need them.
  auto &DT = FAM.getResult<DominatorTreeAnalysis>(F);
  auto &LI = FAM.getResult<LoopAnalysis>(F);

  const bool StrictLockOrder = resolveStrictLockOrder();
  DenseSet<Instruction *> SuppressedCFGProofs;
  DenseSet<CallBase *> SuppressedVirtualizations;
  while (true) {
    Analyzer A(F, DT, LI, StrictLockOrder, SuppressedCFGProofs,
               SuppressedVirtualizations);
    jeandle::PEAResult Attempt = A.run();
    if (!A.getRetryVirtualizationAllocationSites().empty()) {
      bool AddedSuppression = false;
      for (CallBase *Site : A.getRetryVirtualizationAllocationSites()) {
        if (!SuppressedVirtualizations.insert(Site).second)
          continue;
        AddedSuppression = true;
        LLVM_DEBUG({
          dbgs() << "PEA: fresh retry suppressing allocation ";
          Site->printAsOperand(dbgs(), false);
          dbgs() << " in @" << F.getName() << "\n";
        });
      }
      // The winner keeps each rejected allocation real before assigning an
      // ObjectID or recording effects. Every retry must add at least one new
      // stable site, so structural/materialization and final-use suppression
      // share one finite fresh-analysis fixpoint.
      if (!AddedSuppression)
        return jeandle::PEAResult();
      continue;
    }
    if (A.hasInvalidDeoptObligation()) {
      bool AddedSuppression = false;
      for (CallBase *Site : A.getInvalidDeoptAllocationSites())
        AddedSuppression |= SuppressedVirtualizations.insert(Site).second;
      // Every retry must retain at least one additional stable ordinary
      // allocation site. An obligation with no ordinary source leaf, or one
      // that only reports already-suppressed sites, cannot make progress.
      if (!AddedSuppression)
        return jeandle::PEAResult();
      continue;
    }

    ArrayRef<Instruction *> InvalidProofs = A.getInvalidCFGProofKillers();
    if (InvalidProofs.empty())
      return Attempt;

    // Each killer is a stable instruction in untouched input IR. Record every
    // invalid proof discovered this attempt at once, so the fixpoint converges
    // in a small number of retries instead of one terminator per retry (which
    // made large methods re-analyze O(#recorded-proofs) times). The loop still
    // terminates: each retry must suppress at least one previously-unsuppressed
    // terminator, and the set of terminators is finite. A retry that suppresses
    // nothing new indicates an invariant failure; terminate conservatively.
    bool AddedSuppression = false;
    for (Instruction *Killer : InvalidProofs)
      AddedSuppression |= SuppressedCFGProofs.insert(Killer).second;
    if (!AddedSuppression)
      return jeandle::PEAResult();
  }
}
