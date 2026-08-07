//===- SafepointUtils.cpp - Jeandle safepoint utilities ------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/SafepointUtils.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/ScalarEvolution.h"
#include "llvm/Analysis/ScalarEvolutionExpressions.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/CommandLine.h"
#include <climits>

using namespace llvm;

static cl::opt<bool> EnableSafepointElimination(
    "jeandle-enable-safepoint-elim", cl::init(true),
    cl::desc("Master switch for Jeandle safepoint poll transformations."));

static cl::opt<uint64_t> LoopStripMiningIter(
    "jeandle-loop-strip-mining-iter", cl::init(1000),
    cl::desc("Short-loop poll-elimination budget and strip-mining batch size. "
             "0 disables strip mining."));

static cl::opt<bool> EnableInclusiveLoopVersioning(
    "jeandle-enable-inclusive-loop-versioning", cl::init(true),
    cl::desc("Clone supported runtime-risk inclusive loops behind a no-wrap "
             "guard so the safe version can be strip-mined."));

uint64_t llvm::jeandle::getLoopStripMiningIter() { return LoopStripMiningIter; }

bool llvm::jeandle::isSafepointEliminationEnabled() {
  return EnableSafepointElimination;
}

bool llvm::jeandle::isStripMiningEnabled() {
  return getLoopStripMiningIter() != 0;
}

bool llvm::jeandle::isInclusiveLoopVersioningEnabled() {
  return EnableInclusiveLoopVersioning;
}

bool llvm::jeandle::isSafepointPoll(const Instruction &I) {
  const auto *CI = dyn_cast<CallInst>(&I);
  if (!CI || CI->isIndirectCall())
    return false;
  const Function *Callee = CI->getCalledFunction();
  return Callee && Callee->getName() == "jeandle.safepoint_poll";
}

bool llvm::jeandle::isSafepoint(const Instruction &I) {
  return isSafepointPoll(I) || isGuaranteedSafepointCall(I);
}

bool llvm::jeandle::isGuaranteedSafepointCall(const Instruction &I) {
  const auto *CB = dyn_cast<CallBase>(&I);
  if (!CB || isSafepointPoll(I) ||
      CB->getOperandBundle(LLVMContext::OB_deopt) == std::nullopt ||
      CB->hasFnAttr(Attribute::NotGuaranteedSafepoint))
    return false;
  if (const Function *Callee = CB->getCalledFunction())
    if (Callee->hasFnAttribute(Attribute::NotGuaranteedSafepoint))
      return false;
  return true;
}

bool llvm::jeandle::canProveExclusiveNoWrap(const SCEVAddRecExpr *AR,
                                            const APInt &Step,
                                            const SCEV *LimitS,
                                            const Instruction *CtxI,
                                            bool Signed, bool Increasing,
                                            ScalarEvolution &SE) {
  if (Step.abs().isOne())
    return true;
  if (Signed ? AR->hasNoSignedWrap() : AR->hasNoUnsignedWrap())
    return true;

  unsigned BW = AR->getType()->getIntegerBitWidth();
  ICmpInst::Predicate Pred;
  APInt Bound;
  if (Increasing) {
    Pred = Signed ? ICmpInst::ICMP_SLE : ICmpInst::ICMP_ULE;
    Bound = Signed ? APInt::getSignedMaxValue(BW) : APInt::getMaxValue(BW);
    Bound -= Step;
    Bound += 1;
  } else {
    if (Step.isMinSignedValue())
      return false;
    APInt AbsStep = Step.abs();
    Pred = Signed ? ICmpInst::ICMP_SGE : ICmpInst::ICMP_UGE;
    Bound = Signed ? APInt::getSignedMinValue(BW) : APInt::getMinValue(BW);
    Bound += AbsStep;
    Bound -= 1;
  }
  return SE.isKnownPredicateAt(Pred, LimitS, SE.getConstant(Bound), CtxI);
}

bool llvm::jeandle::canProveInclusiveNoWrap(const SCEVAddRecExpr *AR,
                                            const APInt &Step, Value *Limit,
                                            const SCEV *LimitS,
                                            const Instruction *CtxI,
                                            bool Signed, bool Increasing,
                                            ScalarEvolution &SE) {
  if (!isGuaranteedNotToBeUndefOrPoison(Limit))
    return false;
  if (Signed ? AR->hasNoSignedWrap() : AR->hasNoUnsignedWrap())
    return true;

  unsigned BW = AR->getType()->getIntegerBitWidth();
  ICmpInst::Predicate Pred;
  APInt Margin;
  if (Increasing) {
    Pred = Signed ? ICmpInst::ICMP_SLT : ICmpInst::ICMP_ULT;
    Margin = Signed ? APInt::getSignedMaxValue(BW) : APInt::getMaxValue(BW);
    Margin -= Step;
    Margin += 1;
  } else {
    if (Step.isMinSignedValue())
      return false;
    APInt AbsStep = Step.abs();
    Pred = Signed ? ICmpInst::ICMP_SGT : ICmpInst::ICMP_UGT;
    Margin = Signed ? APInt::getSignedMinValue(BW) : APInt::getMinValue(BW);
    Margin += AbsStep;
    Margin -= 1;
  }
  const SCEV *MarginS = SE.getConstant(Margin);
  return SE.isKnownPredicate(Pred, LimitS, MarginS) ||
         SE.isKnownPredicateAt(Pred, LimitS, MarginS, CtxI);
}

std::optional<APInt> llvm::jeandle::getConstantAddStep(Value *V, PHINode *Phi) {
  auto *BO = dyn_cast<BinaryOperator>(V);
  if (!BO || BO->getOpcode() != Instruction::Add)
    return std::nullopt;

  Value *Other = nullptr;
  if (BO->getOperand(0) == Phi)
    Other = BO->getOperand(1);
  else if (BO->getOperand(1) == Phi)
    Other = BO->getOperand(0);
  else
    return std::nullopt;

  auto *Step = dyn_cast<ConstantInt>(Other);
  if (!Step || Step->isZero())
    return std::nullopt;
  return Step->getValue();
}

bool llvm::jeandle::isStripMinedPoll(const Instruction &I) {
  if (!isSafepointPoll(I))
    return false;
  return cast<CallInst>(&I)->hasFnAttr(jeandle::Attribute::StripMinedPoll);
}

bool llvm::jeandle::isMarkedStripMinedInner(Loop &L) {
  Loop *Outer = L.getParentLoop();
  if (!Outer)
    return false;
  BasicBlock *OuterLatch = Outer->getLoopLatch();
  if (!OuterLatch)
    return false;
  return llvm::any_of(*OuterLatch, isStripMinedPoll);
}

bool llvm::jeandle::backedgeCountProvablyLessThan(Loop &L,
                                                  uint64_t ExclusiveLimit,
                                                  ScalarEvolution &SE) {
  const SCEV *MaxBTC = SE.getSymbolicMaxBackedgeTakenCount(&L);
  if (!isa<SCEVCouldNotCompute>(MaxBTC) && MaxBTC->getType()->isIntegerTy()) {
    unsigned BW = SE.getTypeSizeInBits(MaxBTC->getType());
    if (BW < 64 && !isUIntN(BW, ExclusiveLimit))
      return true;
    const SCEV *Limit = SE.getConstant(MaxBTC->getType(), ExclusiveLimit);
    if (SE.isKnownPredicate(ICmpInst::ICMP_ULT, MaxBTC, Limit) ||
        SE.isKnownPredicateAt(ICmpInst::ICMP_ULT, MaxBTC, Limit,
                              L.getHeader()->getTerminator()) ||
        SE.isLoopEntryGuardedByCond(&L, ICmpInst::ICMP_ULT, MaxBTC, Limit))
      return true;
  }

  const auto *ConstantMax =
      dyn_cast<SCEVConstant>(SE.getConstantMaxBackedgeTakenCount(&L));
  if (!ConstantMax)
    return false;
  const APInt &Value = ConstantMax->getAPInt();
  if (Value.getBitWidth() < 64 && !isUIntN(Value.getBitWidth(), ExclusiveLimit))
    return true;
  return Value.ult(APInt(Value.getBitWidth(), ExclusiveLimit));
}

llvm::jeandle::LoopSafepointFacts
llvm::jeandle::LoopSafepointFacts::get(Loop &L, ScalarEvolution &SE) {
  LoopSafepointFacts Facts;
  uint64_t Budget = getLoopStripMiningIter();
  Facts.IsWithinBudget =
      Budget != 0 && backedgeCountProvablyLessThan(L, Budget, SE);
  // This numerical approximation accepts loops whose maximum backedge count
  // is strictly below INT_MAX. It intentionally does not infer countedness
  // from the induction-variable type or loop shape.
  Facts.IsIntCountedEquivalent = backedgeCountProvablyLessThan(L, INT_MAX, SE);
  return Facts;
}

bool llvm::jeandle::hasGuaranteedCallCoverage(Loop &L, DominatorTree &DT) {
  BasicBlock *Latch = L.getLoopLatch();
  if (!Latch)
    return false;
  for (BasicBlock *BB : L.blocks())
    if (DT.dominates(BB, Latch) && llvm::any_of(*BB, [](Instruction &I) {
          return isSafepoint(I) && !isSafepointPoll(I);
        }))
      return true;
  return false;
}

llvm::jeandle::LoopSafepointFacts
llvm::jeandle::LoopSafepointFacts::get(Loop &L, LoopInfo &LI, DominatorTree &DT,
                                       ScalarEvolution &SE) {
  LoopSafepointFacts Facts = get(L, SE);
  BasicBlock *Latch = L.getLoopLatch();
  if (!Latch)
    return Facts;

  for (BasicBlock *BB : L.blocks()) {
    if (!DT.dominates(BB, Latch))
      continue;
    for (Instruction &I : *BB) {
      Facts.HasGuaranteedCallCoverage |= isSafepoint(I) && !isSafepointPoll(I);
      Facts.HasOwnDominatingPoll |=
          LI.getLoopFor(BB) == &L && isSafepointPoll(I);
    }
  }
  return Facts;
}

bool jeandle::AncestorPollRequirements::isRequired(const CallInst &Poll,
                                                   DominatorTree &DT) const {
  if (AnyLatchlessUncoveredAncestor)
    return true;
  return llvm::any_of(Latches, [&](BasicBlock *Latch) {
    return DT.dominates(Poll.getParent(), Latch);
  });
}

llvm::jeandle::AncestorPollRequirements
llvm::jeandle::computeAncestorPollRequirements(Loop &L, LoopInfo &LI,
                                               DominatorTree &DT,
                                               ScalarEvolution &SE) {
  AncestorPollRequirements Requirements;
  for (Loop *Ancestor = L.getParentLoop(); Ancestor;
       Ancestor = Ancestor->getParentLoop()) {
    LoopSafepointFacts Facts = LoopSafepointFacts::get(*Ancestor, LI, DT, SE);
    // A maximum backedge count strictly below INT_MAX exempts an ancestor only
    // when strip mining is disabled, matching deleteLoopPolls and the coverage
    // verifier: only then does the loop drop all its own polls, so it need not
    // depend on descendant polls either. With strip mining enabled such a loop
    // still keeps (or receives) a poll, and exempting it could let a relocated
    // descendant poll leave its backedge path uncovered.
    if (Facts.IsWithinBudget ||
        (!isStripMiningEnabled() && Facts.IsIntCountedEquivalent) ||
        Facts.HasGuaranteedCallCoverage || Facts.HasOwnDominatingPoll)
      continue;

    BasicBlock *Latch = Ancestor->getLoopLatch();
    if (!Latch) {
      Requirements.AnyLatchlessUncoveredAncestor = true;
      break;
    }
    Requirements.Latches.push_back(Latch);
  }
  return Requirements;
}

// ===--------------------------------------------------------------------===//
// Loop coverage analysis (C2 PhaseIdealLoop::check_safepts /
// remove_safepoints). Pure analysis: computes each loop's coverage state
// without mutating the IR.
// ===--------------------------------------------------------------------===//

namespace {

BasicBlock *getIDomBlock(DominatorTree &DT, BasicBlock *BB) {
  auto *IDom = DT.getNode(BB)->getIDom();
  return IDom ? IDom->getBlock() : nullptr;
}

// A genuine (guaranteed-safepoint) call in BB covers a loop whose latch it
// dominates. Deopt-bundle leaf/alloc/lock fast paths are excluded (they carry
// deopt STATE but never reach a VM safepoint); the explicit poll is separate.
bool blockHasDeoptCall(BasicBlock *BB) {
  return llvm::any_of(*BB, [](Instruction &I) {
    return jeandle::isSafepoint(I) && !jeandle::isSafepointPoll(I);
  });
}

CallInst *firstPollInBlock(BasicBlock *BB) {
  for (Instruction &I : *BB)
    if (jeandle::isSafepointPoll(I))
      return cast<CallInst>(&I);
  return nullptr;
}

// C2 allpaths_check_safepts fallback: when the idom-path scan finds no call, no
// local poll, and no sub-loop poll, walk every backward path from the latch
// over in-loop predecessors, terminating each path at the first safepoint, and
// tag the closest-to-latch sub-loop poll on each path required.
void allpathsMarkRequired(Loop &L, LoopInfo &LI,
                          jeandle::RequiredPolls &Required) {
  BasicBlock *Latch = L.getLoopLatch();
  if (!Latch)
    return;
  SmallVector<BasicBlock *, 8> Stack;
  SmallPtrSet<BasicBlock *, 16> Visited;
  Stack.push_back(Latch);
  Visited.insert(Latch);
  while (!Stack.empty()) {
    BasicBlock *BB = Stack.pop_back_val();
    if (blockHasDeoptCall(BB))
      continue; // a call safepoint terminates this path
    if (CallInst *P = firstPollInBlock(BB)) {
      // Any poll terminates the path; a sub-loop poll is one this loop depends
      // on and must keep.
      if (LI.getLoopFor(BB) != &L)
        Required.insert(P);
      continue;
    }
    for (BasicBlock *Pred : predecessors(BB))
      if (L.contains(Pred) && Visited.insert(Pred).second)
        Stack.push_back(Pred);
  }
}

} // namespace

// Phase 1 (C2 IdealLoopTree::check_safepts). Scan the dominator chain from the
// latch up through the header. A deopt-call on that spine (site A), or a
// sub-loop already proven covered (site B), means the loop reaches a safepoint
// every iteration (HasSfpt). A local poll on the spine is recorded as the
// keep-one keeper, but the scan continues past it: a guaranteed-safepoint call
// further up still dominates the latch, so it covers the loop (C2 _has_call ⇒
// keep_one=false) and the loop can drop all of its deleteable polls. Otherwise
// a sub-loop poll on the spine is one this loop may depend on — tag it required
// so the sub-loop keeps it. A sub-loop poll alone never sets HasSfpt on the
// outer loop (it is protected, not used as delete-all coverage), exactly as in
// C2.
void llvm::jeandle::analyzeLoop(Loop &L, LoopInfo &LI, DominatorTree &DT,
                                SmallPtrSetImpl<Loop *> &HasSfpt,
                                RequiredPolls &Required) {
  BasicBlock *Latch = L.getLoopLatch();
  if (!Latch) {
    // A multi-latch loop cannot select one keeper that covers every backedge.
    // Its own polls are never deleted, and conservatively protecting every
    // descendant poll prevents an inner finite loop from removing coverage that
    // one of those backedges depends on.
    for (BasicBlock *BB : L.blocks()) {
      if (LI.getLoopFor(BB) == &L)
        continue;
      for (Instruction &I : *BB)
        if (jeandle::isSafepointPoll(I))
          Required.insert(cast<CallInst>(&I));
    }
    return;
  }
  bool HasCall = false;
  bool HasLocal = false;
  CallInst *NonlocalPoll = nullptr;
  // Walk the dominator chain from latch up through the header (an LLVM header,
  // unlike C2's head node, can itself hold a poll). C2's check_safepts walks
  // tail..head-exclusive; we include the header so a header poll counts as this
  // loop's local keeper.
  for (BasicBlock *BB = Latch; BB && L.contains(BB);
       BB = getIDomBlock(DT, BB)) {
    if (blockHasDeoptCall(BB)) { // site A: call coverage
      HasCall = true;
      break;
    }
    if (CallInst *P = firstPollInBlock(BB)) {
      if (LI.getLoopFor(BB) == &L) {
        // A local poll — this loop's, the closest to the latch on the dom chain
        // — is the keep-one keeper. Unlike C2's check_safepts, which sets
        // has_local_ncsfpt and breaks, keep walking toward the header: a
        // guaranteed-safepoint call further up the spine also dominates the
        // latch, so it runs every iteration and covers the loop regardless of
        // this poll.
        HasLocal = true;
        continue;
      }
      if (!NonlocalPoll)
        NonlocalPoll = P; // sub-loop poll on the spine
      continue;
    }
    // site B: a sub-loop on the spine that is already covered propagates
    // coverage up (ultimately traces to a call). Checked only on blocks that
    // hold no safepoint of their own, matching C2's else-branch.
    Loop *Sub = LI.getLoopFor(BB);
    if (Sub != &L && Sub->getLoopLatch() == BB && HasSfpt.contains(Sub)) {
      HasCall = true;
      break;
    }
  }
  if (HasCall) {
    HasSfpt.insert(&L);
    return;
  }
  if (!L.getSubLoops().empty() && !HasLocal) {
    if (NonlocalPoll)
      Required.insert(NonlocalPoll);
    else
      allpathsMarkRequired(L, LI, Required);
  }
}

// Phase 2 keeper selection (C2 remove_safepoints keep_one idom-path keeper).
// The latch-closest poll this loop owns on the dominator chain, preferring one
// required by an ancestor (it must survive anyway); otherwise any dominating
// poll. Returns null if the loop has no single-latch keeper.
CallInst *llvm::jeandle::findKeepOne(Loop &L, LoopInfo &LI, DominatorTree &DT,
                                     const RequiredPolls &Required) {
  BasicBlock *Latch = L.getLoopLatch();
  if (!Latch)
    return nullptr;
  // Prefer an ancestor-required keeper; otherwise take any dominating poll.
  // Walk the dominator chain latch-up through the header (a header poll is a
  // valid keeper — the header dominates the latch).
  for (bool RequiredOnly : {true, false}) {
    for (BasicBlock *BB = Latch; BB && L.contains(BB);
         BB = getIDomBlock(DT, BB)) {
      if (LI.getLoopFor(BB) != &L)
        continue;
      for (Instruction &I : llvm::reverse(*BB)) {
        if (!jeandle::isSafepointPoll(I))
          continue;
        auto *P = cast<CallInst>(&I);
        if (RequiredOnly && !Required.contains(P))
          continue;
        return P;
      }
    }
  }
  return nullptr;
}
