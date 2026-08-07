//===- SafepointUtils.h - Jeandle safepoint utilities ---------*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_SAFEPOINTUTILS_H
#define LLVM_TRANSFORMS_JEANDLE_SAFEPOINTUTILS_H

#include "llvm/ADT/APInt.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include <cstdint>
#include <optional>

namespace llvm {

class Function;
class BasicBlock;
class Instruction;
class CallInst;
class Loop;
class LoopInfo;
class PHINode;
class SCEV;
class SCEVAddRecExpr;
class ScalarEvolution;
class Value;
class DominatorTree;

namespace jeandle {

bool isSafepointPoll(const Instruction &I);
bool isSafepoint(const Instruction &I);
bool isGuaranteedSafepointCall(const Instruction &I);

uint64_t getLoopStripMiningIter();
bool isSafepointEliminationEnabled();
bool isStripMiningEnabled();
bool isInclusiveLoopVersioningEnabled();

bool backedgeCountProvablyLessThan(Loop &L, uint64_t ExclusiveLimit,
                                   ScalarEvolution &SE);

struct LoopSafepointFacts {
  bool IsWithinBudget = false;
  bool IsIntCountedEquivalent = false;
  bool HasGuaranteedCallCoverage = false;
  bool HasOwnDominatingPoll = false;

  static LoopSafepointFacts get(Loop &L, ScalarEvolution &SE);
  static LoopSafepointFacts get(Loop &L, LoopInfo &LI, DominatorTree &DT,
                                ScalarEvolution &SE);
};

// A guaranteed-safepoint call in a block dominating the latch is reached on
// every iteration, so the loop needs no back-edge poll of its own (C2's
// _has_call / "Then no need for a safept!").
bool hasGuaranteedCallCoverage(Loop &L, DominatorTree &DT);

bool isEmptyLoopPollDeletionCandidate(Loop &L, LoopInfo &LI, DominatorTree &DT,
                                      ScalarEvolution &SE);

// The ancestor-chain verdict for a loop's polls, computed once per loop
// instead of once per poll (the ancestors and their facts do not change
// across a loop's polls). A poll in the loop is required iff some uncovered
// ancestor has no latch, or the poll's block dominates an uncovered
// ancestor's latch.
struct AncestorPollRequirements {
  bool AnyLatchlessUncoveredAncestor = false;
  SmallVector<BasicBlock *, 4> Latches;

  bool isRequired(const CallInst &Poll, DominatorTree &DT) const;
};

AncestorPollRequirements computeAncestorPollRequirements(Loop &L, LoopInfo &LI,
                                                         DominatorTree &DT,
                                                         ScalarEvolution &SE);

using RequiredPolls = SmallPtrSet<CallInst *, 8>;

// Phase 1 (C2 IdealLoopTree::check_safepts). Process loops innermost-first:
// for each loop, decide whether it already reaches a safepoint every iteration
// (insert into HasSfpt) and record sub-loop polls an enclosing loop depends on
// (insert into Required). Pure analysis — does not mutate the IR.
void analyzeLoop(Loop &L, LoopInfo &LI, DominatorTree &DT,
                 SmallPtrSetImpl<Loop *> &HasSfpt, RequiredPolls &Required);

// Phase 2 (C2 remove_safepoints keep_one). The latch-closest poll this loop
// owns on the dominator chain, preferring one an ancestor requires (it must
// survive anyway). Returns null if no single poll dominates every back-edge
// path.
CallInst *findKeepOne(Loop &L, LoopInfo &LI, DominatorTree &DT,
                      const RequiredPolls &Required);

// A safepoint poll that SafepointStripMining relocated onto the outer
// back-edge of a strip-mined nest: a jeandle.safepoint_poll call carrying the
// jeandle.strip-mined-poll call-site attribute.
bool isStripMinedPoll(const Instruction &I);

// A loop is the poll-free, batch-bounded inner of a strip-mined nest iff its
// parent loop's latch holds a strip-mined poll (isStripMinedPoll). The marker
// travels with the relocated poll, so it cannot outlive the coverage it
// certifies. Callers are the passes adjacent to SafepointStripMining in the
// pipeline (after-strip-mining deletion and the coverage verifier), which
// trust the marker; anything later must not rely on it.
bool isMarkedStripMinedInner(Loop &L);

constexpr unsigned StripMineStrideOverflowWidenBits = 64;

std::optional<APInt> getConstantAddStep(Value *V, PHINode *Phi);

bool canProveExclusiveNoWrap(const SCEVAddRecExpr *AR, const APInt &Step,
                             const SCEV *LimitS, const Instruction *CtxI,
                             bool Signed, bool Increasing, ScalarEvolution &SE);

bool canProveInclusiveNoWrap(const SCEVAddRecExpr *AR, const APInt &Step,
                             Value *Limit, const SCEV *LimitS,
                             const Instruction *CtxI, bool Signed,
                             bool Increasing, ScalarEvolution &SE);

} // namespace jeandle
} // namespace llvm

#endif // LLVM_TRANSFORMS_JEANDLE_SAFEPOINTUTILS_H
