//===- SafepointElimination.cpp - Jeandle Safepoint Elimination -----------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
///
/// Eliminate `jeandle.safepoint_poll` calls placed on the back-edge of a loop
/// when the loop's trip count is provably bounded, so that downstream LLVM
/// optimizations (vectorization, LICM, loop-unroll, ...) are not blocked by
/// an opaque call in the loop body.
///
/// This mirrors HotSpot C2's safepoint-strip optimization on CountedLoops and
/// GraalVM's `LoopSafepointEliminationPhase`. A loop is classified "bounded"
/// when either:
///   (A) `SE.getConstantMaxBackedgeTakenCount(L)` is a concrete constant not
///       larger than `-jeandle-short-loop-max-iter`; or
///   (B) (opt-in via `-jeandle-sp-elim-32bit-range=true`) the SCEV-known
///       constant max backedge-taken count fits in 32 unsigned bits,
///       mirroring GraalVM's `iterationRangeIsIn32Bit` rule, which covers
///       the common `for (int i = 0; i < n; ++i)` case where the symbolic
///       limit forces SCEV to settle on INT_MAX/UINT_MAX as the max
///       backedge-taken count. Rule (B) is *off by default* until the
///       strip-mining transform (see below) lands — a 2^32-iteration i32
///       loop with no outer safepoint can stall GC for seconds, so without
///       a strip-mining fallback we keep the poll.
///
/// Only safepoint polls that lie on every back-edge path are removed. A poll
/// in a side-exit slow path (e.g. before an `uncommon_trap`) carries deopt
/// JVM state and is intentionally preserved.
///
/// Loops whose trip count we cannot bound are left untouched; a follow-up
/// strip-mining transform (HotSpot C2's `OuterStripMinedLoopNode` / Graal's
/// equivalent) will wrap them in an outer loop carrying a single safepoint
/// poll, but that transform is out of scope for this pass.
///
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/SafepointElimination.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/LoopAnalysisManager.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/ScalarEvolution.h"
#include "llvm/Analysis/ScalarEvolutionExpressions.h"
#include "llvm/IR/BasicBlock.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Debug.h"
#include "llvm/Transforms/Scalar/LoopPassManager.h"

using namespace llvm;

#define DEBUG_TYPE "safepoint-elimination"

static cl::opt<uint64_t> ShortLoopMaxIter(
    "jeandle-short-loop-max-iter", cl::init(1ULL << 20),
    cl::desc("Counted loops whose SCEV-known max backedge-taken count is <= "
             "this value have their back-edge safepoint polls removed."));

static cl::opt<bool> EnableSafepointElim(
    "jeandle-enable-safepoint-elim", cl::init(true),
    cl::desc("Master switch for the SafepointElimination pass. Setting this "
             "to false makes the pass a no-op (back-edge safepoint polls in "
             "counted loops are preserved). Useful for A/B comparison."));

static cl::opt<bool> AllowRangeIn32Bit(
    "jeandle-sp-elim-32bit-range", cl::init(false),
    cl::desc("Allow eliminating back-edge safepoints in counted loops whose "
             "SCEV-known constant max backedge-taken count fits in 32 unsigned "
             "bits, mirroring GraalVM's iterationRangeIsIn32Bit rule. Off by "
             "default until the strip-mining transform lands: a 2^32-iter i32 "
             "loop with no outer safepoint can stall GC by seconds. Once "
             "strip mining is in, the long-i32 case will be routed there and "
             "this flag will be repurposed."));

namespace {

constexpr StringRef SafepointPollName = "jeandle.safepoint_poll";

bool isSafepointPoll(const Instruction &I) {
  const auto *CI = dyn_cast<CallInst>(&I);
  if (!CI || CI->isIndirectCall())
    return false;
  const Function *Callee = CI->getCalledFunction();
  return Callee && Callee->getName() == SafepointPollName;
}

enum class BoundKind { ShortRunning, RangeIn32Bit, Unbounded };

/// Trip-count classification using SCEV's constant max backedge-taken count
/// alone. This is a sound upper bound on iterations across *all* loop exits
/// and wrap semantics, computed by SCEV independently of whether any single
/// exit-cmp's operands are syntactically loop-invariant — so it works on
/// pre-canonicalization IR where self-cycling phis still hide an otherwise-
/// invariant value behind a phi that LoopInfo treats as in-loop.
BoundKind classifyBoundFromSCEV(Loop *L, ScalarEvolution &SE) {
  const SCEV *MaxBTC = SE.getConstantMaxBackedgeTakenCount(L);
  LLVM_DEBUG(dbgs() << "  MaxBTC=" << *MaxBTC << "\n");
  if (const auto *MaxC = dyn_cast<SCEVConstant>(MaxBTC)) {
    const APInt &V = MaxC->getAPInt();
    if (V.ule(ShortLoopMaxIter))
      return BoundKind::ShortRunning;
    // GraalVM's iterationRangeIsIn32Bit: any loop whose trip count is
    // representable in 32 unsigned bits is treated as a Java-int counted
    // loop. This covers the common `for (int i = 0; i < n; ++i)` case where
    // the symbolic limit forces SCEV to settle on INT_MAX/UINT_MAX as the
    // max backedge-taken count.
    if (AllowRangeIn32Bit && V.getActiveBits() <= 32)
      return BoundKind::RangeIn32Bit;
  }
  return BoundKind::Unbounded;
}

/// A safepoint poll is on the loop's back-edge path iff its block dominates
/// the latch. Side-exit blocks that branch to `uncommon_trap; unreachable`
/// have no CFG path to the latch, so the dominator check excludes them
/// automatically — no PostDominatorTree needed.
bool isBackEdgePoll(CallInst *CI, Loop *L, DominatorTree &DT) {
  BasicBlock *Latch = L->getLoopLatch();
  if (!Latch)
    return false;
  return DT.dominates(CI->getParent(), Latch);
}

SmallVector<CallInst *, 4>
collectBackEdgePolls(Loop *L, LoopInfo &LI, DominatorTree &DT) {
  SmallVector<CallInst *, 4> Out;
  for (BasicBlock *BB : L->blocks()) {
    // Only consider polls owned by this loop, not by an inner sub-loop —
    // those are handled when the LPM visits the sub-loop.
    if (LI.getLoopFor(BB) != L)
      continue;
    for (Instruction &I : *BB) {
      if (!isSafepointPoll(I))
        continue;
      auto *CI = cast<CallInst>(&I);
      if (isBackEdgePoll(CI, L, DT))
        Out.push_back(CI);
    }
  }
  return Out;
}

bool tryEliminateInLoop(Loop *L, LoopStandardAnalysisResults &AR) {
  LoopInfo &LI = AR.LI;
  ScalarEvolution &SE = AR.SE;
  DominatorTree &DT = AR.DT;

  LLVM_DEBUG(dbgs() << "SafepointElimination: visiting loop with header "
                    << L->getHeader()->getName() << "\n");

  if (!L->getLoopLatch()) {
    LLVM_DEBUG(dbgs() << "  no unique latch, skip\n");
    return false;
  }

  SmallVector<CallInst *, 4> Polls = collectBackEdgePolls(L, LI, DT);
  if (Polls.empty()) {
    LLVM_DEBUG(dbgs() << "  no back-edge polls, skip\n");
    return false;
  }

  // SCEV-only trip-count check. If SCEV can prove the loop's trip count is
  // bounded by a representable constant, drop the back-edge polls outright.
  // This decision does NOT require identifying which value is the IV —
  // SCEV's max-BTC already accounts for every exit and every wrap case
  // across the whole loop body.
  BoundKind BK = classifyBoundFromSCEV(L, SE);
  if (BK == BoundKind::Unbounded) {
    LLVM_DEBUG(dbgs() << "  unbounded; preserving polls\n");
    return false;
  }

  LLVM_DEBUG({
    dbgs() << "  bounded ("
           << (BK == BoundKind::ShortRunning ? "short-running"
                                             : "range-in-32-bit")
           << "); removing " << Polls.size() << " back-edge poll(s)\n";
  });
  for (CallInst *P : Polls)
    P->eraseFromParent();
  SE.forgetLoop(L);
  return true;
}

} // end anonymous namespace

PreservedAnalyses SafepointElimination::run(Loop &L, LoopAnalysisManager &AM,
                                            LoopStandardAnalysisResults &AR,
                                            LPMUpdater &U) {
  Function &F = *L.getHeader()->getParent();

  // Only act on compiled Java methods. The module-level named metadata mirrors
  // the existing pattern in InsertGCBarriers. The check is per-loop here but
  // is just a pointer compare against a NamedMDList lookup, so the overhead
  // is negligible.
  if (!EnableSafepointElim)
    return PreservedAnalyses::all();

  if (!F.getParent()->getNamedMetadata(jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();

  if (!tryEliminateInLoop(&L, AR))
    return PreservedAnalyses::all();

  // We only erased calls. CFG and loop nest are intact, the IV recurrences and
  // DT all stay valid. SCEV may have stale exit-count caches on the loop
  // whose poll we just removed — `tryEliminateInLoop` invalidated those for
  // us via SE.forgetLoop, so we can claim SE is preserved too.
  return getLoopPassPreservedAnalyses();
}
