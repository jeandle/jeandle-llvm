//===- LockCoarsening.cpp - Coarsen adjacent Java monitors --------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This pass runs while Jeandle monitor JavaOps are still opaque.  Candidate
// discovery recognizes four related shapes (adjacent, nested,
// conditional-chain, covered).  Every candidate is proved by the same
// LockStructureVerifier and rewritten by the same LockSlotNormalization step,
// so the rules only decide where to look, not how to rewrite.
//
// The pass is split into three layers:
//   * LockAnalysis: recognize monitor JavaOps and local region boundaries.
//   * LockStructureVerifier: prove the exact local shape before rewriting.
//   * LockSlotNormalization: mechanically retain one BasicLock slot.
// The candidate search and optimization decisions remain in this file.
//
// Constraints
// -----------
// Shared by all rules (correctness, not tuning):
//   * A monitor JavaOp is a nounwind CallInst carrying receiver and BasicLock
//     operands.  This is the frontend contract; another form would need an
//     explicit frontend change.
//   * A candidate retains exactly one outermost enter.  Merging independent
//     enters needs a path-sensitive proof that every path acquires once and
//     that no removed enter is observable, plus unlock cloning on every live
//     path.  This is the main TODO; sibling synchronized blocks are common
//     Java.
//   * Every monitor operation in one candidate has the same receiver identity
//     and locking mode.  Removing an acquisition under a different receiver
//     would change the protected region.
//   * Monitor balance is preserved on every path after the rewrite: a removed
//     enter is dominated by the retained enter, and a removed exit is followed
//     by a surviving unlock or an inserted unlock clone on that path.  This is
//     not "removed ops pair with each other": adjacent folds the first exit and
//     the second enter, so its retained enter pairs with the second region's
//     exit and its retained exit pairs with the removed first exit.  A gap here
//     would leak or double-release a monitor.
//   * A discarded BasicLock slot may only be used by removed monitor ops,
//     retained exits, audited region calls, and lifetime markers that
//     normalization erases or rewrites.  Any other use makes slot
//     normalization unsound.
//   * Every deopt record naming a discarded slot must be mechanically
//     rewritable to the retained lock and owner.
//   * The retained slot must be live wherever a discarded slot was used;
//     normalization redirects those uses to the retained slot and erases or
//     redirects lifetime markers so no two live ranges overlap.
//
// Rule-private constraints:
//
//   adjacent: the first region immediately precedes the second.
//     * The first enter and exit may be in different blocks: supported when a
//       guarded call splits the block.
//     * The first region has exactly one matching monitor exit in total, not
//       merely one normal exit: unwind paths must terminate in deopt/return
//       rather than materialize another monitorexit.  That single exit is both
//       the anchor used to find the second enter and the only unlock template.
//       With a second exit the second region follows only one continuation, so
//       the other path would keep the lock extended with no matching second
//       region and would need its own unlock clone.  Rare in Java source (one
//       lexical synchronized block has one normal exit), but common after
//       inlining: TODO.
//     * The first region is a single-entry subgraph without loops.  The scan
//       must prove the retained enter covers every operation and that no
//       predecessor bypasses it.  Entry from outside is impossible in Java
//       source but can appear after CFG rewriting; a loop is legal Java but
//       uncommon in hot straight-line code: TODO.
//     * The boundary between the regions is transparent straight-line code.
//       Lifetime-marker bookkeeping and second-enter discovery are block-local.
//       Field writes, calls, PHIs and exception dispatch in the gap are common
//       Java: TODO.
//     * The second region is likewise a single-entry subgraph without loops.
//       It may have several matching exits (normal and unwind), but its walk
//       stops at the first monitor operation, so a nested enter there is not
//       recursed into; the nested rule removes it in a separate step.
//
//   nested: a redundant reentrant acquisition under a live outer frame.
//     * The outer enter must be the direct top of the lock stack, with the same
//       receiver and locking mode, and a distinct BasicLock slot.  A reused
//       slot makes the stack proof ambiguous; a different receiver changes
//       lock semantics.
//     * The inner region may contain calls, invokes and multiple normal or
//       unwind exits.  This is the strongest shape and covers synchronized
//       reentrant helpers and recursive synchronized methods after inlining.
//     * The inner slot must not already have a lifetime.end before the inner
//       enter in its block; that would mean the slot is not live there.
//     * A non-inlined nested call is just a call; there is no inner monitor in
//       this function to fold.
//
//   conditional-chain: a sequence of guarded regions.
//     * Shape: exit, two-way branch, an early block containing only transparent
//       operations plus at most one deopt and ending in deopt/return, and a
//       continue block that opens the next region; at least two regions.
//     * Each region has one exit and each successor one predecessor.  The rule
//       clones the retained unlock onto early exits, so those blocks must be
//       frame exits reached only from their branch.  Merges and loops are
//       rejected; catch/finally variants are TODO.
//
//   covered: the CFG fallback rooted at one retained enter.
//     * Starts from one outer region with one exit.  Before the first branch
//       the gap may contain pure computation and memory operations, but no
//       monitor op and no ordinary call; lock extension across a field access
//       is legal, while crossing a call would change observable behavior.
//     * Walks the CFG with an explicit same-object lock stack.  Nested enters
//       are supported.  Branches are allowed only when they rejoin under the
//       retained monitor and end at a retained exit or a deopt/return.  An
//       independent sibling acquisition joined later is not a covered
//       candidate; that is the TODO sibling-merge case.
//     * At depth > 1 a nounwind memory(none) helper may be crossed; a
//       deopt-bearing call is audited.  A plain call at the retained frame ends
//       the path (catch dispatch outside the region) or rejects the candidate.
//     * Revisited (block, depth, last-exit) states are rejected, so loops are
//       not handled here.
//
// TODO (common Java, deferred; need stronger proof or unlock cloning):
//   * general sibling/independent enter merging across arbitrary CFG;
//   * multiple normal exits in the first adjacent region;
//   * non-transparent operations between adjacent regions;
//   * loops inside a region (loop-invariant acquisition plus full unwind);
//   * catch/finally paths that keep a live monitor on an exceptional edge;
//   * crossing arbitrary observable calls inside a live region.
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/LockCoarsening.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/Statistic.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/Analysis/Jeandle/LockAnalysis.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/Jeandle/LockSlotNormalization.h"
#include "llvm/Transforms/Jeandle/LockStructureVerifier.h"

using namespace llvm;
using namespace llvm::jeandle::lock;

#define DEBUG_TYPE "jeandle-lock-coarsening"

STATISTIC(NumCoarsenedBoundaries,
          "Number of adjacent Jeandle monitor boundaries coarsened");
STATISTIC(NumVerifierRejectedCandidates,
          "Number of lock-coarsening candidates rejected by the verifier");

static cl::opt<bool> EnableJeandleLockCoarsening(
    "jeandle-lock-coarsening", cl::init(true), cl::Hidden,
    cl::desc("Coarsen adjacent balanced Jeandle monitor regions"));

namespace {

/// Return the matching exit for an enter, rejecting enters, different locking
/// modes, objects, or BasicLock slots.  Candidate finders use this before
/// recording any exit so their shape checks and the common verifier agree on
/// what "matching" means.
static std::optional<MonitorOp> getMatchingExit(Instruction &I,
                                                const MonitorOp &Enter) {
  std::optional<MonitorOp> Exit = getMonitorOp(I);
  if (!Exit || Exit->IsEnter || Exit->Mode != Enter.Mode ||
      !sameMonitorObject(*Exit, Enter) || !sameMonitorLock(*Exit, Enter))
    return std::nullopt;
  return Exit;
}

/// Record a matching exit and the lifetime.end that closes its slot.  A region
/// may have multiple exits on normal and exceptional edges, so every exit is
/// represented uniformly as a MonitorExit.
static bool recordRegionExit(Instruction &I, const MonitorOp &Enter,
                             MonitorRegionShape &Shape,
                             SmallVectorImpl<CallBase *> &RegionCalls) {
  std::optional<MonitorOp> Exit = getMatchingExit(I, Enter);
  if (!Exit)
    return false;

  if (llvm::any_of(Shape.Exits, [&](const MonitorExit &Known) {
        return Known.Op.Call == Exit->Call;
      }))
    return true;
  Shape.Exits.push_back({*Exit, findSecondLifetimeEnd(*Exit)});
  // The exit itself may carry a deopt bundle naming the BasicLock slot.  Audit
  // it with the other calls in the region before any rewrite.
  if (Exit->Call->hasOperandBundles())
    RegionCalls.push_back(Exit->Call);
  return true;
}

/// Return true when calling Callee cannot make the monitor state observable.
/// The frontend emits small private helpers (for example
/// jeandle.current_thread_obj) as nounwind functions whose bodies only read
/// thread-local state.  Those calls carry no memory attributes, so attribute
/// queries alone reject them.  Prove the property on the body instead: every
/// operation must be non-throwing and read-only, including nested calls.
static bool isReadOnlyHelper(Function &Callee, SmallPtrSetImpl<Function *> &Active,
                             unsigned Depth = 0) {
  if (Depth > 8 || !Active.insert(&Callee).second)
    return false;
  if (Callee.isDeclaration() || !Callee.doesNotThrow()) {
    Active.erase(&Callee);
    return false;
  }
  if (Callee.onlyReadsMemory()) {
    Active.erase(&Callee);
    return true;
  }

  for (BasicBlock &BB : Callee) {
    for (Instruction &I : BB) {
      if (isa<StoreInst>(I) || isa<AtomicRMWInst>(I) || isa<AtomicCmpXchgInst>(I) ||
          isa<FenceInst>(I) || isa<InvokeInst>(I) || isa<CallBrInst>(I) ||
          isa<ResumeInst>(I)) {
        Active.erase(&Callee);
        return false;
      }
      if (auto *CB = dyn_cast<CallBase>(&I)) {
        if (CB->getOperandBundle(LLVMContext::OB_deopt) ||
            !CB->doesNotThrow() || CB->mayWriteToMemory()) {
          Active.erase(&Callee);
          return false;
        }
        if (CB->doesNotAccessMemory() || CB->onlyReadsMemory())
          continue;
        auto *Direct = dyn_cast<Function>(
            CB->getCalledOperand()->stripPointerCasts());
        if (!Direct || !isReadOnlyHelper(*Direct, Active, Depth + 1)) {
          Active.erase(&Callee);
          return false;
        }
      }
    }
  }
  Active.erase(&Callee);
  return true;
}

static bool isReadOnlyHelperCall(CallInst &Call) {
  if (Call.doesNotAccessMemory() || Call.onlyReadsMemory())
    return true;
  auto *Callee =
      dyn_cast<Function>(Call.getCalledOperand()->stripPointerCasts());
  if (!Callee)
    return false;
  // Function-level attributes are authoritative even when the declaration is
  // opaque.  This is how the real JIT declares jeandle.current_thread_obj.
  if (Callee->doesNotThrow() &&
      (Callee->doesNotAccessMemory() || Callee->onlyReadsMemory()))
    return true;
  SmallPtrSet<Function *, 8> Active;
  return isReadOnlyHelper(*Callee, Active);
}

/// Return true for a block that only computes, deoptimizes, and returns.  Such
/// a block terminates the frame and never observes the rewritten monitor, so
/// it may be shared with other inlined copies of the same region.
static bool isDeoptSink(BasicBlock &BB) {
  CallInst *Deopt = nullptr;
  for (Instruction &I : BB) {
    if (getMonitorOp(I) || isa<InvokeInst>(I) || isa<CallBrInst>(I))
      return false;
    if (auto *Call = dyn_cast<CallInst>(&I)) {
      if (Call->getIntrinsicID() != Intrinsic::experimental_deoptimize ||
          Deopt || !Call->getOperandBundle(LLVMContext::OB_deopt))
        return false;
      Deopt = Call;
      continue;
    }
    if (I.isTerminator() && !isa<ReturnInst>(I))
      return false;
  }
  if (!Deopt)
    return false;
  Instruction *After = Deopt->getNextNode();
  while (After && (isa<DbgInfoIntrinsic>(After) || isLifetimeMarker(*After)))
    After = After->getNextNode();
  return After && isa<ReturnInst>(*After) && isa<ReturnInst>(BB.getTerminator());
}

/// How a scanned region may leave the monitored frame.
enum class RegionExitMode {
  /// Exactly one normal monitor exit.  This is the only shape a non-final
  /// region can currently be rewritten into: the surviving exit provides the
  /// unlock template, and every other path must leave the frame through
  /// deopt/return with the monitor still recorded as live.
  SingleNormalExit,
  /// Several matching monitor exits may survive (invoke normal/unwind edges).
  /// Used for the final region, where every exit is retained as-is and no
  /// unlock has to be cloned.
  MultipleNormalExits,
};

/// Facts collected while proving one region's CFG.
struct RegionScanResult {
  SmallVector<BasicBlock *, 8> Blocks;
  SmallVector<CallBase *, 4> Calls;
};

/// Walk a monitored region's CFG after its enter and collect its normal exits.
///
/// The shape comes from a Java body with a guarded exception path inlined into
/// a synchronized block: a pure helper feeds a condition, failure edges
/// deoptimize, and the normal edge reaches the monitor exit.  A deopt path
/// needs no cloned unlock because its bundle still records the live monitor,
/// so it is only required to end in deopt followed by return.
///
/// Both regions share this scanner; Mode decides how many normal exits are
/// acceptable.  Everything else is rejected: loops, entries from outside the
/// region, opaque calls, throwing calls, and malformed deopt blocks.
static bool scanRegionCFG(CallInst &EnterCall, const MonitorOp &Enter,
                          MonitorRegionShape &Shape, RegionExitMode Mode,
                          RegionScanResult &Result,
                          bool AllowSharedDeoptSinks) {
  BasicBlock *EntryBB = EnterCall.getParent();
  SmallVector<std::pair<BasicBlock *, Instruction *>, 8> Worklist;
  SmallPtrSet<BasicBlock *, 8> Visited;
  Worklist.push_back({EntryBB, EnterCall.getNextNode()});
  Result.Blocks.push_back(EntryBB);

  while (!Worklist.empty()) {
    auto [BB, Next] = Worklist.pop_back_val();
    // Scanning a block twice means a loop or a join reached along two paths.
    // The predecessor closure below cannot distinguish those cheaply, so both
    // are rejected instead of being approximated.
    if (!Visited.insert(BB).second)
      return false;

    bool Ended = false;
    for (Instruction *I = Next; I; I = I->getNextNode()) {
      if (getMonitorOp(*I)) {
        if (!recordRegionExit(*I, Enter, Shape, Result.Calls))
          return false;
        Ended = true;
        break;
      }

      if (auto *CB = dyn_cast<CallBase>(I)) {
        if (isa<DbgInfoIntrinsic>(CB) || isLifetimeMarker(*CB))
          continue;
        if (isa<CallBrInst>(CB))
          return false;
        if (auto *Invoke = dyn_cast<InvokeInst>(CB)) {
          // Invoke terminator: both normal and unwind edges stay in the region.
          if (!llvm::is_contained(Result.Calls, Invoke))
            Result.Calls.push_back(Invoke);
          for (BasicBlock *Succ : successors(Invoke)) {
            if (!llvm::is_contained(Result.Blocks, Succ))
              Result.Blocks.push_back(Succ);
            Worklist.push_back({Succ, &Succ->front()});
          }
          Ended = true;
          break;
        }
        auto *Call = dyn_cast<CallInst>(CB);
        if (!Call)
          return false;

        if (Call->getIntrinsicID() == Intrinsic::experimental_deoptimize) {
          // Deopt never resumes in this frame, and its bundle describes the
          // monitor state to restore.  The verifier checks that record.
          if (!Call->getOperandBundle(LLVMContext::OB_deopt))
            return false;
          Instruction *After = Call->getNextNode();
          while (After && (isa<DbgInfoIntrinsic>(After) ||
                           isLifetimeMarker(*After)))
            After = After->getNextNode();
          if (!After || !isa<ReturnInst>(*After))
            return false;
          if (!llvm::is_contained(Result.Calls, Call))
            Result.Calls.push_back(Call);
          Ended = true;
          break;
        }

        if (!Call->doesNotThrow())
          return false;

        // A deopt-bearing call may observe the lock through its bundle and is
        // audited by the verifier.  Any other call is crossable only when it
        // cannot observe memory, which covers frontend helpers such as
        // jeandle.current_thread_obj().
        if (!Call->getOperandBundle(LLVMContext::OB_deopt) &&
            !isReadOnlyHelperCall(*Call))
          return false;
        if (!llvm::is_contained(Result.Calls, Call))
          Result.Calls.push_back(Call);
        continue;
      }

      if (I->isTerminator()) {
        if (!isa<BranchInst>(*I) && !isa<SwitchInst>(*I))
          return false;
        for (BasicBlock *Succ : successors(I->getParent())) {
          // A shared deopt sink is a terminal owner of no monitor state.  Do
          // not pull its other predecessors into the region; the sink itself
          // is still visited and validated when reached from this region.
          if (AllowSharedDeoptSinks && Visited.contains(Succ) &&
              isDeoptSink(*Succ))
            continue;
          if (!llvm::is_contained(Result.Blocks, Succ))
            Result.Blocks.push_back(Succ);
          Worklist.push_back({Succ, &Succ->front()});
        }
        Ended = true;
        break;
      }
    }
    if (!Ended)
      return false;
  }

  // The region is a single-entry subgraph: no block other than the entry may
  // have a predecessor from outside it.  Checking after the closure keeps this
  // order-independent, since a legitimate join may be reached before its
  // second predecessor has been visited.
  for (BasicBlock *BB : Result.Blocks) {
    if (BB == EntryBB)
      continue;
    for (BasicBlock *Pred : predecessors(BB))
      if (!llvm::is_contained(Result.Blocks, Pred) &&
          !(AllowSharedDeoptSinks && isDeoptSink(*BB)))
        return false;
  }

  if (Shape.Exits.empty())
    return false;
  if (Mode == RegionExitMode::SingleNormalExit && Shape.Exits.size() != 1)
    return false;
  return true;
}

/// Adjacent-region discovery, driven from the acquired outer frame rather than
/// from an exit.  Driving from an exit only works while the region is one basic
/// block; a guarded call inside the first region splits its enter and exit
/// across blocks, so the stack frame is the stable identity.
///
/// Typical source shape:
///
///   synchronized (this) { r += a; }
///   synchronized (this) { r += b; }
///
/// A guarded call may split the first block, but the form is still adjacent:
///
///   synchronized (this) { r += a; r += maybeThrow(t); }
///   synchronized (this) { r += b; }
///
/// Limits specific to this rule:
///   * one retained enter; sibling enters are not merged here;
///   * the first region has exactly one matching monitor exit in total, so an
///     unwind path must terminate in deopt/return rather than another exit;
///   * the second region may have several matching exits, but a nested enter
///     stops the walk and is left for the nested rule;
///   * no loops and no entries from outside either region.
static std::optional<MonitorRegion>
findAdjacentCandidate(CallInst &FirstEnterCall, LockStackAnalysis &Stack,
                      LockStructureVerifier &Verifier,
                      const DominatorTree &DT) {
  std::optional<MonitorOp> FirstEnter = getMonitorOp(FirstEnterCall);
  if (!FirstEnter || !FirstEnter->IsEnter)
    return std::nullopt;

  const LockRegion *FirstRegion = Stack.getRegionForEnter(&FirstEnterCall);
  if (!FirstRegion || FirstRegion->Exits.size() != 1)
    return std::nullopt;

  AdjacentRegion Region;
  Region.First.Enter = *FirstEnter;
  RegionScanResult FirstScan;
  if (!scanRegionCFG(FirstEnterCall, *FirstEnter, Region.First,
                     RegionExitMode::SingleNormalExit, FirstScan,
                     /*AllowSharedDeoptSinks=*/true))
    return std::nullopt;
  if (Region.First.Exits.size() != 1)
    return std::nullopt;
  const MonitorOp &FirstExit = Region.First.Exits.front().Op;
  if (!FirstExit.Call || !FirstExit.Call->getParent())
    return std::nullopt;
  Region.FirstRegionBlocks.assign(FirstScan.Blocks.begin(),
                                  FirstScan.Blocks.end());
  Region.FirstRegionCalls.assign(FirstScan.Calls.begin(), FirstScan.Calls.end());

  // The lexical boundary still has to be straight-line: after the single
  // normal first exit only transparent instructions may follow before the
  // sibling acquisition.  Cross-block shapes stop here because the boundary
  // lifetime-marker bookkeeping is block-local by design.
  Instruction *Next =
      nextNonTransparent(*FirstExit.Call, &Region.BoundaryLifetimeMarkers);
  if (!Next)
    return std::nullopt;
  std::optional<MonitorOp> SecondEnter = getMonitorOp(*Next);
  if (!SecondEnter || !SecondEnter->IsEnter ||
      SecondEnter->Mode != FirstExit.Mode ||
      !sameMonitorObject(*SecondEnter, FirstExit))
    return std::nullopt;
  Region.Second.Enter = *SecondEnter;
  // A removed enter/exit takes its operand bundle with it.  Surviving calls in
  // the folded region are audited and rewritten by the verifier/normalization
  // step, so a deopt bundle on the removed monitor itself is not a blocker.

  RegionScanResult SecondScan;
  if (!scanRegionCFG(*Region.Second.Enter.Call, Region.Second.Enter,
                     Region.Second, RegionExitMode::MultipleNormalExits,
                     SecondScan, /*AllowSharedDeoptSinks=*/true))
    return std::nullopt;
  Region.SecondRegionBlocks.assign(SecondScan.Blocks.begin(),
                                   SecondScan.Blocks.end());
  Region.SecondRegionCalls.assign(SecondScan.Calls.begin(),
                                  SecondScan.Calls.end());

  // Candidate construction only establishes the shape.  The separate adjacent
  // proof, including monitor-stack continuity, belongs to the verifier.
  std::string Reason;
  if (!Verifier.verifyAdjacentShape(Region, Stack, DT, &Reason)) {
    ++NumVerifierRejectedCandidates;
    LLVM_DEBUG(dbgs() << "Jeandle adjacent lock coarsening rejected: " << Reason
                      << "\n");
    return std::nullopt;
  }
  return getMonitorRegion(Region);
}

/// Redundant reentrant acquisition.  Typical source shape:
///
///   synchronized (this) {
///     synchronized (this) { r += b; }
///   }
///
/// The same IR appears after inlining a synchronized method that calls another
/// synchronized method on the same receiver:
///
///   synchronized int outer() { return inner(); }
///   synchronized int inner() { ... }
///
/// Only the inner acquisition is removed; the outer one keeps covering it.
static std::optional<MonitorRegion>
findNestedCandidate(CallInst &InnerEnterCall, LockStackAnalysis &Stack,
                    LockStructureVerifier &, const DominatorTree &) {
  std::optional<MonitorOp> InnerEnter = getMonitorOp(InnerEnterCall);
  if (!InnerEnter || !InnerEnter->IsEnter)
    return std::nullopt;
  // The removed enter takes its operand bundle with it.  Calls that remain in
  // the inner region are audited below and by the verifier before their slots
  // are normalized to the retained BasicLock.

  const LockRegion *InnerRegion = Stack.getRegionForEnter(&InnerEnterCall);
  if (!InnerRegion || InnerRegion->Exits.empty())
    return std::nullopt;

  const LockStackState *BeforeInner = Stack.getStateBefore(InnerEnterCall);
  if (!BeforeInner || BeforeInner->Frames.empty())
    return std::nullopt;
  const LockStackFrame &OuterFrame = BeforeInner->Frames.back();
  if (!OuterFrame.isValid() || OuterFrame.Enter == &InnerEnterCall)
    return std::nullopt;

  std::optional<MonitorOp> OuterEnter =
      getMonitorOp(cast<Instruction>(*OuterFrame.Enter));
  if (!OuterEnter || !OuterEnter->IsEnter ||
      OuterEnter->Mode != InnerEnter->Mode ||
      !sameMonitorObject(*OuterEnter, *InnerEnter))
    return std::nullopt;

  Value *InnerLock = InnerEnter->Lock->stripPointerCastsAndAliases();
  Value *OuterLock = OuterEnter->Lock->stripPointerCastsAndAliases();
  if (InnerLock == OuterLock || InnerLock->getType() != OuterLock->getType())
    return std::nullopt;

  MonitorRegion Candidate;
  Candidate.RetainedEnter = *OuterEnter;
  Candidate.RemovedMonitorOps.push_back(*InnerEnter);

  for (CallInst *ExitCall : InnerRegion->Exits) {
    std::optional<MonitorOp> Exit =
        getMatchingExit(cast<Instruction>(*ExitCall), *InnerEnter);
    if (!Exit)
      return std::nullopt;
    if (Exit->Call->hasOperandBundles() &&
        !llvm::is_contained(Candidate.RegionCalls, Exit->Call))
      Candidate.RegionCalls.push_back(Exit->Call);

    const LockStackState *BeforeExit = Stack.getStateBefore(*ExitCall);
    if (!BeforeExit || BeforeExit->Frames.empty() ||
        BeforeExit->Frames.back().Enter != &InnerEnterCall)
      return std::nullopt;

    Candidate.RemovedMonitorOps.push_back(*Exit);
    if (IntrinsicInst *End = findSecondLifetimeEnd(*Exit))
      Candidate.LifetimeMarkersToErase.push_back(End);
  }

  // Remove at most one lifetime.start for the inner slot.  It must be the
  // nearest start before the inner enter.
  for (Instruction &I : *InnerEnterCall.getParent()) {
    if (&I == &InnerEnterCall)
      break;
    if (isLifetimeFor(&I, Intrinsic::lifetime_start, InnerLock))
      Candidate.LifetimeMarkersToErase.push_back(&I);
    else if (isLifetimeFor(&I, Intrinsic::lifetime_end, InnerLock))
      return std::nullopt;
  }

  // Any deopt-bearing call inside the inner region may name the inner slot.
  for (User *Usr : InnerLock->users())
    if (auto *CB = dyn_cast<CallBase>(Usr))
      if (CB != InnerEnter->Call &&
          !llvm::is_contained(Candidate.RegionCalls, CB))
        Candidate.RegionCalls.push_back(CB);

  return Candidate;
}

/// Recognize the common prefix of the CFG-based rules: one straight-line
/// balanced region whose unique exit matches the candidate enter.  The caller
/// then inspects the CFG following that exit to classify the shape.
static std::optional<MonitorOp>
getSingleExitRegion(const MonitorOp &Enter, const LockStackAnalysis &Stack) {
  const LockRegion *Outer = Stack.getRegionForEnter(Enter.Call);
  if (!Outer || Outer->Exits.size() != 1)
    return std::nullopt;

  std::optional<MonitorOp> Exit =
      getMatchingExit(cast<Instruction>(*Outer->Exits.front()), Enter);
  if (!Exit)
    return std::nullopt;
  return Exit;
}

/// Return true when a path leaving the retained region cannot observe the
/// monitor being coarsened.  The supported Jeandle shape is a guarded
/// postcondition deopt block or a normal Java return.  Both paths leave the
/// frame and never resume inside the region; the rewrite inserts the retained
/// unlock at these points.
static bool isSafeEarlyExit(const Instruction &I) {
  if (isa<ReturnInst>(I))
    return true;
  const auto *CB = dyn_cast<CallBase>(&I);
  return CB && CB->getIntrinsicID() == Intrinsic::experimental_deoptimize;
}

/// Candidate discovery for the straight-line chain emitted by a sequence of
/// guarded source-level conditions:
///
///   synchronized (this) { r += a; }
///   if (early) return -1;
///   synchronized (this) { r += b; }
///   if (early) return -1;
///   synchronized (this) { r += c; }
///
/// The frontend lowers each early return to a deopt/return edge.  The IR shape
/// is therefore:
///
///   enter A; ...; exit A
///   br cond, early_exit, next
///   early_exit: deopt/return
///   next: enter B; ...; exit B; br cond, early_exit, ...
///
/// The current AdjacentRegion path only folds two regions and the general
/// CoveredRegion path rejects a frame-terminating branch.  This shape is common
/// in the original JMH conditional benchmarks.  We accept it only when:
///   * every region is a single-exit straight-line region on one predecessor,
///   * the taken edge only deoptimizes or returns,
///   * the monitor object and locking mode are identical.
/// Every early exit receives an unlock clone, so the retained monitor cannot
/// escape on a path that exits before the final region.
static std::optional<CoveredRegion>
findConditionalChainCandidate(CallInst &EnterCall, LockStackAnalysis &Stack,
                              LockStructureVerifier &,
                              const DominatorTree &) {
  std::optional<MonitorOp> Enter = getMonitorOp(EnterCall);
  if (!Enter || !Enter->IsEnter)
    return std::nullopt;
  std::optional<MonitorOp> FirstExit = getSingleExitRegion(*Enter, Stack);
  if (!FirstExit)
    return std::nullopt;

  CoveredRegion Candidate;
  Candidate.RetainedEnter = *Enter;
  Candidate.RemovedMonitorOps.push_back(*FirstExit);
  if (FirstExit->Call->hasOperandBundles())
    Candidate.RegionCalls.push_back(FirstExit->Call);
  if (Enter->Call->hasOperandBundles())
    Candidate.RegionCalls.push_back(Enter->Call);
  if (IntrinsicInst *End = findSecondLifetimeEnd(*FirstExit))
    Candidate.LifetimeMarkersToErase.push_back(End);
  CallInst *CurrentExit = FirstExit->Call;
  unsigned FoldedRegions = 1;

  while (true) {
    Instruction *Next = CurrentExit->getNextNode();
    while (Next && isBoundaryTransparent(*Next))
      Next = Next->getNextNode();
    if (!Next)
      return std::nullopt;

    auto *Term = dyn_cast<BranchInst>(Next);
    if (!Term || Term->isUnconditional() || Term->getNumSuccessors() != 2)
      return std::nullopt;

    BasicBlock *Early = Term->getSuccessor(0);
    BasicBlock *Continue = Term->getSuccessor(1);
    if (Early == Continue ||
        Continue->getSinglePredecessor() != Term->getParent() ||
        Early->getSinglePredecessor() != Term->getParent())
      return std::nullopt;

    Instruction *EarlyTerm = Early->getTerminator();
    if (!EarlyTerm || !isSafeEarlyExit(*EarlyTerm))
      return std::nullopt;
    Instruction *EarlyExitPoint = EarlyTerm;
    bool SawDeopt = false;
    for (Instruction &I : *Early) {
      if (&I == EarlyTerm)
        continue;
      if (getMonitorOp(I))
        return std::nullopt;
      if (auto *CB = dyn_cast<CallBase>(&I)) {
        if (CB->getIntrinsicID() != Intrinsic::experimental_deoptimize)
          return std::nullopt;
        if (SawDeopt)
          return std::nullopt;
        SawDeopt = true;
        Candidate.RegionCalls.push_back(CB);
        // The deopt call is the last operation that can observe the lock
        // state on this path.  Insert the cloned unlock before it, not before
        // the following return.
        EarlyExitPoint = &I;
        continue;
      }
      if (!isBoundaryTransparent(I))
        return std::nullopt;
    }

    Instruction *First = &Continue->front();
    while (First && isBoundaryTransparent(*First))
      First = First->getNextNode();
    std::optional<MonitorOp> NextEnter =
        First ? getMonitorOp(*First) : std::nullopt;
    if (!NextEnter || !NextEnter->IsEnter || NextEnter->Mode != Enter->Mode ||
        !sameMonitorObject(*NextEnter, *Enter))
      return std::nullopt;

    Instruction *ExitI = NextEnter->Call->getNextNode();
    std::optional<MonitorOp> Exit;
    while (ExitI && !(Exit = getMonitorOp(*ExitI))) {
      if (ExitI->isTerminator())
        return std::nullopt;
      ExitI = ExitI->getNextNode();
    }
    if (!Exit || Exit->IsEnter || Exit->Mode != Enter->Mode ||
        !sameMonitorObject(*Exit, *Enter) ||
        !sameMonitorLock(*Exit, *NextEnter))
      return std::nullopt;

    Candidate.EarlyExitPoints.push_back({CurrentExit, EarlyExitPoint});
    Candidate.RemovedMonitorOps.push_back(*NextEnter);
    Candidate.RemovedMonitorOps.push_back(*Exit);
    if (NextEnter->Call->hasOperandBundles())
      Candidate.RegionCalls.push_back(NextEnter->Call);
    if (Exit->Call->hasOperandBundles())
      Candidate.RegionCalls.push_back(Exit->Call);
    if (IntrinsicInst *End = findSecondLifetimeEnd(*Exit))
      Candidate.LifetimeMarkersToErase.push_back(End);
    for (Instruction *Prev = NextEnter->Call->getPrevNode(); Prev;
         Prev = Prev->getPrevNode()) {
      if (!isBoundaryTransparent(*Prev))
        break;
      if (!isLifetimeFor(Prev, Intrinsic::lifetime_start, NextEnter->Lock))
        continue;
      Candidate.LifetimeMarkersToErase.push_back(Prev);
      break;
    }
    ++FoldedRegions;
    CurrentExit = Exit->Call;

    // Stop at the final region; a later conditional/opaque operation is left
    // for a future candidate rather than folded without proof.
    Instruction *AfterExit = CurrentExit->getNextNode();
    while (AfterExit && isBoundaryTransparent(*AfterExit))
      AfterExit = AfterExit->getNextNode();
    if (!AfterExit)
      return std::nullopt;
    if (getMonitorOp(*AfterExit) || !isa<BranchInst>(AfterExit))
      break;
  }

  if (FoldedRegions < 2)
    return std::nullopt;
  std::optional<MonitorOp> FinalExit = getMonitorOp(*CurrentExit);
  if (!FinalExit || FinalExit->IsEnter)
    return std::nullopt;
  // The final exit is the surviving release on the normal path.  Earlier
  // iterations added it to RemovedMonitorOps while walking the chain, so undo
  // that here and retain its lifetime.end as well.
  llvm::erase_if(Candidate.RemovedMonitorOps, [&](const MonitorOp &Op) {
    return Op.Call == FinalExit->Call;
  });
  if (IntrinsicInst *End = findSecondLifetimeEnd(*FinalExit))
    llvm::erase(Candidate.LifetimeMarkersToErase, End);
  if (IntrinsicInst *End = findSecondLifetimeEnd(*FinalExit))
    if (!llvm::is_contained(Candidate.LifetimeMarkersToKeep, End))
      Candidate.LifetimeMarkersToKeep.push_back(End);
  Candidate.RetainedExits.push_back(*FinalExit);
  return Candidate;
}

/// Full-CFG fallback for a region whose branches rejoin under the retained
/// monitor.  Typical source shape:
///
///   synchronized (this) { r += a; }
///   if (left) {
///     synchronized (this) { r += b; }
///   } else {
///     synchronized (this) { r += c; }
///   }
///   synchronized (this) { r += d; }
///
/// The walk starts at the first region, follows both arms, treats their enters
/// as nested redundancy, and requires every path to end at a retained exit or
/// a deopt/return.  Independent sibling enters that never rejoin under the
/// retained monitor remain unsupported.
static std::optional<CoveredRegion>
findCoveredCandidate(CallInst &EnterCall, LockStackAnalysis &Stack,
                     LockStructureVerifier &, const DominatorTree &) {
  std::optional<MonitorOp> Enter = getMonitorOp(EnterCall);
  if (!Enter || !Enter->IsEnter)
    return std::nullopt;
  std::optional<MonitorOp> FirstExit = getSingleExitRegion(*Enter, Stack);
  if (!FirstExit)
    return std::nullopt;

  CoveredRegion Candidate;
  Candidate.RetainedEnter = *Enter;
  Candidate.RemovedMonitorOps.push_back(*FirstExit);
  // Only the outer enter is retained.  Enters discovered below it are
  // redundant nested acquisitions and are removed; two sibling entries that
  // merge into this exit are not supported because there is no single
  // acquisition that dominates both.

  // Leave straight-line adjacency to the dedicated adjacent-region matcher,
  // which has the exact lifetime-marker and exception proof.  This fallback
  // handles only CFG shapes where the first exit does not lead directly to
  // another same-object enter.
  // The gap may still contain pure SSA computation after the first exit.
  // Only a monitor or an observable operation before the branch makes this
  // path ambiguous; actual safety is established by the CFG walk below.
  Instruction *AfterFirstExit = FirstExit->Call->getNextNode();
  for (; AfterFirstExit; AfterFirstExit = AfterFirstExit->getNextNode()) {
    if (getMonitorOp(*AfterFirstExit))
      return std::nullopt;
    auto *CB = dyn_cast<CallBase>(AfterFirstExit);
    if (CB && !isa<DbgInfoIntrinsic>(CB) && !isLifetimeMarker(*CB))
      return std::nullopt;
    if (AfterFirstExit->isTerminator())
      break;
  }
  if (!AfterFirstExit)
    return std::nullopt;

  struct Item {
    BasicBlock *BB;
    Instruction *Next;
    SmallVector<CallInst *, 4> Locks;
    MonitorOp LastExit;
  };
  struct SeenState {
    const BasicBlock *BB;
    unsigned Depth;
    const CallInst *LastExit;
  };

  SmallVector<Item, 16> Worklist;
  SmallVector<SeenState, 32> Seen;
  auto AlreadySeen = [&](const Item &It) {
    return llvm::any_of(Seen, [&](const SeenState &S) {
      return S.BB == It.BB && S.Depth == It.Locks.size() &&
             S.LastExit == It.LastExit.Call;
    });
  };
  auto PushSuccessors = [&](const Item &It) {
    for (BasicBlock *Succ : successors(It.BB))
      Worklist.push_back({Succ, &Succ->front(), It.Locks, It.LastExit});
  };
  auto RecordUnique = [&](SmallVectorImpl<MonitorOp> &Ops,
                          const MonitorOp &Op) {
    if (!llvm::any_of(Ops, [&](const MonitorOp &Existing) {
          return Existing.Call == Op.Call;
        }))
      Ops.push_back(Op);
  };

  Worklist.push_back({FirstExit->Call->getParent(),
                      FirstExit->Call->getNextNode(),
                      {&EnterCall},
                      MonitorOp{}});
  while (!Worklist.empty()) {
    Item It = Worklist.pop_back_val();
    if (AlreadySeen(It))
      return std::nullopt;
    Seen.push_back(
        {It.BB, static_cast<unsigned>(It.Locks.size()), It.LastExit.Call});

    SmallVector<CallInst *, 4> Locks = It.Locks;
    MonitorOp LastExit = It.LastExit;
    bool Ended = false;

    for (Instruction *I = It.Next; I; I = I->getNextNode()) {
      std::optional<MonitorOp> Op = getMonitorOp(*I);
      if (!Op) {
        if (auto *CB = dyn_cast<CallBase>(I)) {
          if (isa<DbgInfoIntrinsic>(CB) || isLifetimeMarker(*CB))
            continue;
          if (!CB->getOperandBundle(LLVMContext::OB_deopt)) {
            // After a nested region has been closed, a plain call at the
            // retained frame is outside the coarsening region.  Java
            // exception dispatch following an unwind is the common example.
            // End this path instead of auditing catch-dispatch code as if it
            // were still protected by the second monitor.
            if (Locks.size() == 1 && LastExit) {
              RecordUnique(Candidate.RetainedExits, LastExit);
              Ended = true;
              break;
            }
            // Inline-driven Java probes may leave a non-throwing helper call
            // between the second enter and its exit (for example
            // current_thread_obj).  Crossing it does not change the monitor
            // state or expose the discarded BasicLock.
            if (Locks.size() > 1 && CB->doesNotThrow() &&
                CB->doesNotAccessMemory()) {
              if (!llvm::is_contained(Candidate.RegionCalls, CB))
                Candidate.RegionCalls.push_back(CB);
              continue;
            }
            return std::nullopt;
          }
          if (!llvm::is_contained(Candidate.RegionCalls, CB))
            Candidate.RegionCalls.push_back(CB);
        }
        if (isa<ReturnInst>(I) || isa<ResumeInst>(I) ||
            isa<UnreachableInst>(I)) {
          // A deopt is a frame exit: the interpreter reconstructs the held
          // monitor from the deopt bundle, so the retained unlock must NOT be
          // cloned before it.  The deopt call is the instruction immediately
          // before this return in Jeandle IR.
          const Instruction *Prev = I->getPrevNode();
          const auto *Deopt = dyn_cast_or_null<CallBase>(Prev);
          if (Locks.size() > 1 && Deopt &&
              Deopt->getIntrinsicID() == Intrinsic::experimental_deoptimize) {
            Ended = true;
            break;
          }
          if (Locks.size() != 1 || !LastExit)
            return std::nullopt;
          RecordUnique(Candidate.RetainedExits, LastExit);
          Ended = true;
          break;
        }
        if (I->isTerminator()) {
          PushSuccessors({It.BB, I, Locks, LastExit});
          Ended = true;
          break;
        }
        continue;
      }

      if (Op->Mode != Enter->Mode || !sameMonitorObject(*Op, *Enter))
        return std::nullopt;

      // Every removed exit owns a BasicLock whose lifetime must be closed at
      // that exit.  Once the exit is erased the following lifetime.end would
      // otherwise keep the retained slot live across the folded region and
      // make nested lifetime ranges overlap.
      auto RecordExitLifetimeEnd = [&](Instruction *Exit,
                                       const MonitorOp &ExitOp) {
        for (Instruction *Next = Exit->getNextNode(); Next;
             Next = Next->getNextNode()) {
          auto *II = dyn_cast<IntrinsicInst>(Next);
          if (!II || !isLifetimeMarker(*II))
            return;
          if (II->getIntrinsicID() != Intrinsic::lifetime_end)
            continue;
          if (getLifetimePointer(*II) !=
              ExitOp.Lock->stripPointerCastsAndAliases())
            continue;
          if (!llvm::is_contained(Candidate.LifetimeMarkersToErase, II))
            Candidate.LifetimeMarkersToErase.push_back(II);
          return;
        }
      };

      if (Op->IsEnter) {
        if (Op->Call == &EnterCall)
          return std::nullopt;
        Locks.push_back(Op->Call);
        RecordUnique(Candidate.RemovedMonitorOps, *Op);
        LastExit = MonitorOp{};

        // A nested region normally opens a new BasicLock lifetime.  Remove the
        // matching lifetime.start together with the enter; leaving it behind
        // would start a second live range on the retained slot.
        for (Instruction *Prev = I->getPrevNode(); Prev;
             Prev = Prev->getPrevNode()) {
          if (!isBoundaryTransparent(*Prev))
            break;
          if (!isLifetimeFor(Prev, Intrinsic::lifetime_start, Op->Lock))
            continue;
          if (!llvm::is_contained(Candidate.LifetimeMarkersToErase, Prev))
            Candidate.LifetimeMarkersToErase.push_back(Prev);
          break;
        }
        continue;
      }

      if (Locks.size() <= 1)
        return std::nullopt;
      std::optional<MonitorOp> Top =
          getMonitorOp(cast<Instruction>(*Locks.back()));
      if (!Top || !sameMonitorLock(*Op, *Top))
        return std::nullopt;
      Locks.pop_back();
      LastExit = *Op;
      RecordUnique(Candidate.RemovedMonitorOps, *Op);
      RecordExitLifetimeEnd(I, *Op);
      if (Op->Call->hasOperandBundles() &&
          !llvm::is_contained(Candidate.RegionCalls, Op->Call))
        Candidate.RegionCalls.push_back(Op->Call);
    }

    if (Ended)
      continue;
    if (Locks.size() != 1)
      return std::nullopt;
    PushSuccessors({It.BB, nullptr, Locks, LastExit});
  }

  if (Candidate.RetainedExits.empty())
    return std::nullopt;

  // Retained exits are the last exit on their path, so they must not remain
  // in the removed set.
  llvm::erase_if(Candidate.RemovedMonitorOps, [&](const MonitorOp &Op) {
    return Op.IsEnter == false &&
           llvm::any_of(Candidate.RetainedExits, [&](const MonitorOp &Exit) {
             return Exit.Call == Op.Call;
           });
  });
  // A retained exit's own lifetime.end still closes the retained slot.  Only
  // markers belonging to removed monitor operations are stale.
  for (const MonitorOp &Exit : Candidate.RetainedExits) {
    IntrinsicInst *End = findSecondLifetimeEnd(Exit);
    if (!End)
      continue;
    llvm::erase(Candidate.LifetimeMarkersToErase, End);
    if (!llvm::is_contained(Candidate.LifetimeMarkersToKeep, End))
      Candidate.LifetimeMarkersToKeep.push_back(End);
  }
  if (Candidate.RemovedMonitorOps.empty())
    return std::nullopt;
  return Candidate;
}

using CandidateFinder = std::optional<MonitorRegion> (*)(
    CallInst &, LockStackAnalysis &, LockStructureVerifier &,
    const DominatorTree &);

struct CoarseningRule {
  StringRef Name;
  CandidateFinder Find;
};

/// Scan the function for the first region accepted by any rule.  Candidate
/// discovery is rule-specific, but every candidate is verified and rewritten
/// through the same path.  A successful rewrite invalidates the monitor-stack
/// analysis, so the caller rebuilds it before the next attempt.
static bool coarsenOne(Function &F, LockStackAnalysis &Stack,
                       LockStructureVerifier &Verifier,
                       const DominatorTree &DT) {
  static const CoarseningRule Rules[] = {
      {"adjacent", findAdjacentCandidate},
      {"nested", findNestedCandidate},
      {"conditional-chain", findConditionalChainCandidate},
      {"covered", findCoveredCandidate},
  };

  for (const CoarseningRule &Rule : Rules) {
    for (BasicBlock &BB : F) {
      for (Instruction &I : BB) {
        auto *CI = dyn_cast<CallInst>(&I);
        if (!CI)
          continue;

        std::optional<MonitorRegion> Candidate =
            Rule.Find(*CI, Stack, Verifier, DT);
        if (!Candidate)
          continue;

        std::string Reason;
        if (!Verifier.verifyBeforeRewrite(*Candidate, &Stack, &Reason)) {
          ++NumVerifierRejectedCandidates;
          LLVM_DEBUG(dbgs() << "Jeandle " << Rule.Name
                            << " lock coarsening rejected: " << Reason << "\n");
          continue;
        }

        LockSlotNormalization Plan = planLockSlotNormalization(*Candidate);
        applyLockSlotNormalization(*Candidate, Plan);
        ++NumCoarsenedBoundaries;
        LLVM_DEBUG(dbgs() << "Jeandle " << Rule.Name
                          << " lock coarsening retained " << *Plan.RetainedLock
                          << "\n");
        return true;
      }
    }
  }
  return false;
}

} // namespace

PreservedAnalyses LockCoarsening::run(Function &F,
                                      FunctionAnalysisManager &FAM) {
  if (!EnableJeandleLockCoarsening)
    return PreservedAnalyses::all();

  const DominatorTree &DT = FAM.getResult<DominatorTreeAnalysis>(F);

  bool Changed = false;
  while (true) {
    // All candidate searches within one iteration observe the same IR.  A
    // successful rewrite invalidates the analysis, so rebuild it before the
    // next attempt.
    LockStackAnalysis Stack(F);
    LockStructureVerifier Verifier;
    if (!coarsenOne(F, Stack, Verifier, DT))
      break;
    Changed = true;
  }
  return Changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
}
