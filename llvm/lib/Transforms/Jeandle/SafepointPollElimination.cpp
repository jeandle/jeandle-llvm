//===- SafepointPollElimination.cpp - Safepoint poll elimination ---------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/SafepointPollElimination.h"
#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/CFG.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/ScalarEvolution.h"
#include "llvm/Analysis/ScalarEvolutionExpressions.h"
#include "llvm/IR/BasicBlock.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/JeandleUtils.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/Support/Debug.h"
#include "llvm/Transforms/Jeandle/SafepointUtils.h"
#include "llvm/Transforms/Utils/LoopUtils.h"
#include "llvm/Transforms/Utils/ScalarEvolutionExpander.h"

using namespace llvm;

#define DEBUG_TYPE "safepoint-poll-elimination"

namespace {

using jeandle::analyzeLoop;
using jeandle::findKeepOne;
using jeandle::isSafepoint;
using jeandle::isSafepointPoll;
using jeandle::RequiredPolls;

[[maybe_unused]] StringRef modeName(SafepointPollEliminationMode Mode) {
  switch (Mode) {
  case SafepointPollEliminationMode::Early:
    return "early";
  case SafepointPollEliminationMode::AfterStripMining:
    return "after-strip-mining";
  case SafepointPollEliminationMode::LoopDeletionPrep:
    return "loop-deletion-prep";
  }
  llvm_unreachable("unknown SafepointPollEliminationMode");
}

// Collapse redundant polls within a block. A basic block is straight-line
// control: once entered, every instruction up to the terminator executes, so
// any safepoint later in the block is guaranteed to run after an earlier one.
// A safepoint request that arrives after the earlier poll is therefore caught
// by the later safepoint, making the earlier poll redundant. Each poll's deopt
// state is self-contained, so dropping the earlier poll loses nothing. This
// generalizes C2's SafePointNode::Identity patterns A/B (back-to-back poll,
// poll-after-call) to "earlier poll with any later safepoint in the same
// block". A "later safepoint" is a poll or a *guaranteed*-safepoint call (C2
// Pattern B's `guaranteed_safepoint()` gate, callnode.cpp:1330): a leaf/alloc/
// lock fast path carries deopt STATE but never catches a request, so it does
// not make an earlier poll redundant. Deopt calls are never deleted (they do
// real work); only `jeandle.safepoint_poll` calls are removed.
bool collapseRedundantPolls(BasicBlock &BB) {
  // The last poll or guaranteed-safepoint call in the block catches every
  // request an earlier poll would have caught, so every poll strictly before it
  // is redundant. Find that last safepoint, then erase the polls that precede
  // it.
  Instruction *LastSafepoint = nullptr;
  bool hasGuaranteedSafepoint = false;
  for (Instruction &I : BB) {
    if (isSafepoint(I) && !isSafepointPoll(I)) {
      hasGuaranteedSafepoint = true;
      break;
    }

    if (isSafepointPoll(I))
      LastSafepoint = &I;
  }

  bool Changed = false;

  if (hasGuaranteedSafepoint) {
    // Delete all safepoint polls.
    for (Instruction &I : llvm::make_early_inc_range(BB)) {
      if (isSafepointPoll(I)) {
        auto *P = cast<CallInst>(&I);
        LLVM_DEBUG(dbgs() << "  collapse: erased a redundant poll in "
                          << BB.getName() << "\n");
        P->eraseFromParent();
        Changed = true;
      }
    }
    return Changed;
  }

  if (!LastSafepoint)
    return Changed;

  for (Instruction &I : llvm::make_early_inc_range(BB)) {
    if (&I == LastSafepoint)
      break;
    if (!isSafepointPoll(I))
      continue;
    auto *P = cast<CallInst>(&I);
    LLVM_DEBUG(dbgs() << "  collapse: erased a redundant poll in "
                      << BB.getName() << "\n");
    P->eraseFromParent();
    Changed = true;
  }
  return Changed;
}

// ===--------------------------------------------------------------------===//
// Two-phase loop safepoint elimination (C2 check_safepts + remove_safepoints)
//
// Phase 1 (analyzeLoop) computes, without mutating the IR, each loop's coverage
// state — whether it already reaches a safepoint every iteration and so need
// not keep its own poll (C2's _has_sfpt) — and records polls that an enclosing
// loop depends on (C2's _required_safept). Phase 2
// (deleteLoopPolls) erases polls from each loop based on that state. Splitting
// analysis from mutation mirrors C2 and avoids the ordering hazards of erasing
// polls while still walking the loop tree.
// ===--------------------------------------------------------------------===//

// Phase 2 (C2 remove_safepoints + is_deleteable_safept + counted_loop's
// keep_one decision). A loop with a provable small trip count, a strip-mined
// inner (marked via the relocated poll's attribute), or one already covered
// (HasSfpt) drops all its own deleteable polls;
// otherwise it keeps one dominating poll (prune gate: no dominating keeper ⇒
// delete nothing).
static bool deleteLoopPolls(Loop &L, LoopInfo &LI, DominatorTree &DT,
                            ScalarEvolution &SE,
                            const SmallPtrSetImpl<Loop *> &HasSfpt,
                            const RequiredPolls &Required,
                            SafepointPollEliminationMode Mode) {
  SmallVector<CallInst *, 4> OwnPolls;
  for (BasicBlock *BB : L.blocks()) {
    if (LI.getLoopFor(BB) != &L)
      continue;
    for (Instruction &I : *BB)
      if (isSafepointPoll(I))
        OwnPolls.push_back(cast<CallInst>(&I));
  }
  if (OwnPolls.empty())
    return false;

  BasicBlock *Latch = L.getLoopLatch();
  if (!Latch) {
    LLVM_DEBUG(dbgs() << "  poll-elimination<" << modeName(Mode) << "> loop "
                      << L.getHeader()->getName()
                      << ": keep-all (multi-latch loop)\n");
    return false;
  }

  auto IsDeleteable = [&](CallInst *P) { return !Required.contains(P); };

  jeandle::LoopSafepointFacts Facts = jeandle::LoopSafepointFacts::get(L, SE);
  const char *Reason = nullptr;
  if (jeandle::isMarkedStripMinedInner(L))
    Reason = "strip-mined-inner"; // poll attribute: poll-free, bounded
  else if (L.isInnermost() && Facts.IsWithinBudget)
    Reason = "within-budget"; // short loop: trip count bounds time-to-safepoint
  else if (HasSfpt.contains(&L))
    Reason = "call-covered"; // call/sub-loop coverage reaches a safepoint
  else if (!jeandle::isStripMiningEnabled() && Facts.IsIntCountedEquivalent)
    Reason = "int-counted-no-strip-mining"; // bounded trip => C2 T_INT
  bool DeleteAll = Reason != nullptr;

  if (DeleteAll) {
    bool Changed = false;
    [[maybe_unused]] unsigned Erased = 0;
    for (CallInst *P : OwnPolls) {
      if (IsDeleteable(P)) {
        P->eraseFromParent();
        Changed = true;
        ++Erased;
      } else {
        LLVM_DEBUG(dbgs() << "    poll-elimination: kept ancestor-required "
                             "poll in "
                          << P->getParent()->getName() << "\n");
      }
    }
    LLVM_DEBUG(dbgs() << "  poll-elimination<" << modeName(Mode) << "> loop "
                      << L.getHeader()->getName() << ": delete-all (" << Reason
                      << "), erased " << Erased << " of " << OwnPolls.size()
                      << " poll(s)\n");
    if (Changed)
      SE.forgetLoop(&L);
    return Changed;
  }

  // keep-one: retain one dominating poll, erase the rest.
  CallInst *Keep = findKeepOne(L, LI, DT, Required);
  if (!Keep) {
    // no single poll dominates all paths — prune gate
    LLVM_DEBUG(dbgs() << "  poll-elimination<" << modeName(Mode) << "> loop "
                      << L.getHeader()->getName()
                      << ": keep-all (no dominating keeper)\n");
    return false;
  }
  bool Changed = false;
  [[maybe_unused]] unsigned Erased = 0;
  for (CallInst *P : OwnPolls)
    if (P != Keep && IsDeleteable(P)) {
      P->eraseFromParent();
      Changed = true;
      ++Erased;
    }
  LLVM_DEBUG(dbgs() << "  poll-elimination<" << modeName(Mode) << "> loop "
                    << L.getHeader()->getName() << ": keep-one (keeper in "
                    << Keep->getParent()->getName() << "), erased " << Erased
                    << " of " << OwnPolls.size() << " poll(s)\n");
  return Changed;
}

// Complete loop-tree poll deletion (C2 check_safepts over every loop
// + remove_safepoints), shared by Early when strip mining is disabled and
// AfterStripMining after CFG surgery. It analyzes coverage state
// innermost-first (so a sub-loop's state is settled
// before enclosing loops read it), then deletes per the analyzed state.
struct EmptyLoopExitValueCheck {
  PHINode *Phi;
  Value *OriginalValue;
  const SCEV *ExitValue;
};

struct EmptyLoopPollRemovalPlan {
  Loop *L;
  BasicBlock *Preheader;
  BasicBlock *ExitingBlock;
  BasicBlock *ExitBlock;
  SmallVector<CallInst *, 2> Polls;
  SmallVector<EmptyLoopExitValueCheck, 2> ExitValues;
  // Exit phis whose incoming value is computed in the loop but is used only by
  // dead LCSSA phi chains (or nothing). No state needs preserving for them;
  // their incoming value is poisoned on apply so deleting the loop leaves no
  // dangling use.
  SmallVector<PHINode *, 2> DeadExitPhis;

  /// Pre-condition re-check before applying: this plan still matches the
  /// IR (the loop nest has the same preheader, exiting, exit, LCSSA,
  /// dedicated-exit shape; the recorded polls are still inside the nest and
  /// alive; each exit value's LCSSA phi still carries its original incoming
  /// value). Sibling-plan application can invalidate a queued plan, so each
  /// plan validates itself before it applies (C2's two-phase analyze-then-
  /// mutate pattern, guarded here against interference).
  bool stillStructurallyValid(LoopInfo &LI, DominatorTree &DT) const;
};

bool hasOnlyDeoptStateUses(Value *V, Loop &L, SmallPtrSetImpl<Value *> &Visited,
                           bool &ReachesSafepoint) {
  if (!Visited.insert(V).second)
    return true;
  for (Use &U : V->uses()) {
    auto *I = dyn_cast<Instruction>(U.getUser());
    if (!I)
      return false;
    if (jeandle::isSafepoint(*I)) {
      auto *CB = dyn_cast<CallBase>(I);
      if (!CB || !CB->isBundleOperand(&U) ||
          !CB->isOperandBundleOfType(LLVMContext::OB_deopt, U.getOperandNo()))
        return false;
      ReachesSafepoint = true;
      continue;
    }
    if (I->isDebugOrPseudoInst())
      continue;
    auto *Phi = dyn_cast<PHINode>(I);
    if (!Phi || L.contains(Phi) ||
        !hasOnlyDeoptStateUses(Phi, L, Visited, ReachesSafepoint))
      return false;
  }
  return true;
}

// A loop is empty for this transform only when it contains pure control/IV
// computation plus direct Jeandle polls. Memory accesses and other calls stay
// out of scope even when LLVM could otherwise prove them dead.
std::optional<EmptyLoopPollRemovalPlan>
buildEmptyLoopPollRemovalPlan(Loop *L, LoopInfo &LI, DominatorTree &DT,
                              ScalarEvolution &SE) {
  if (!L->isLCSSAForm(DT) || !L->hasDedicatedExits())
    return std::nullopt;

  BasicBlock *Preheader = L->getLoopPreheader();
  BasicBlock *ExitingBlock = L->getExitingBlock();
  BasicBlock *ExitBlock = L->getUniqueExitBlock();
  if (!Preheader || !ExitingBlock || !ExitBlock || ExitBlock->isEHPad() ||
      ExitBlock->getSinglePredecessor() != ExitingBlock)
    return std::nullopt;

  auto *PreheaderBr = dyn_cast<BranchInst>(Preheader->getTerminator());
  if (!PreheaderBr || !PreheaderBr->isUnconditional() ||
      PreheaderBr->getSuccessor(0) != L->getHeader())
    return std::nullopt;

  // Every loop in the region being removed must be known to terminate. This
  // permits deleting an empty loop nest as one transaction, including the
  // descendant poll on which an enclosing loop's coverage depends.
  for (Loop *Nested : L->getLoopsInPreorder())
    if (isa<SCEVCouldNotCompute>(SE.getConstantMaxBackedgeTakenCount(Nested)))
      return std::nullopt;

  SmallVector<CallInst *, 2> Polls;
  for (BasicBlock *BB : L->blocks()) {
    for (Instruction &I : *BB) {
      if (isSafepointPoll(I)) {
        Polls.push_back(cast<CallInst>(&I));
        continue;
      }
      if (isa<CallBase>(I) || I.mayReadOrWriteMemory() ||
          I.mayHaveSideEffects())
        return std::nullopt;
    }
  }
  if (Polls.empty())
    return std::nullopt;
  // Only ancestors outside the deleted nest can require one of its polls. An
  // ancestor inside the nest disappears in the same transaction.
  jeandle::AncestorPollRequirements AncestorRequirements =
      jeandle::computeAncestorPollRequirements(*L, LI, DT, SE);
  for (CallInst *P : Polls)
    if (AncestorRequirements.isRequired(*P, DT))
      return std::nullopt;

  SCEVExpander Rewriter(SE, "jeandle-empty-loop-check");
  SmallVector<EmptyLoopExitValueCheck, 2> ExitValues;
  SmallVector<PHINode *, 2> DeadExitPhis;
  // Keep this narrow: reconstruct values that survive solely for safepoint
  // deopt state, not general reductions with observable live-outs.
  for (PHINode &Phi : ExitBlock->phis()) {
    if (Phi.getNumIncomingValues() != 1 ||
        Phi.getIncomingBlock(0) != ExitingBlock)
      return std::nullopt;

    Value *Incoming = Phi.getIncomingValue(0);
    auto *IncomingInst = dyn_cast<Instruction>(Incoming);
    if (!IncomingInst || !L->contains(IncomingInst))
      continue;

    SmallPtrSet<Value *, 8> Visited;
    bool ReachesSafepoint = false;
    if (!hasOnlyDeoptStateUses(&Phi, *L, Visited, ReachesSafepoint))
      return std::nullopt;
    if (!ReachesSafepoint) {
      // The phi is dead state (unused, or feeds only dead LCSSA phi chains),
      // not a live-out. It must not block deletion; poison its in-loop
      // incoming on apply so no dangling use remains.
      DeadExitPhis.push_back(&Phi);
      continue;
    }
    if (!SE.isSCEVable(Phi.getType()))
      return std::nullopt;

    const SCEV *ExitValue = SE.getSCEVAtScope(IncomingInst, L->getParentLoop());
    if (isa<SCEVCouldNotCompute>(ExitValue) ||
        !SE.isLoopInvariant(ExitValue, L) ||
        !Rewriter.isSafeToExpandAt(ExitValue, Preheader->getTerminator()))
      return std::nullopt;
    ExitValues.push_back({&Phi, Incoming, ExitValue});
  }
  return EmptyLoopPollRemovalPlan{L,
                                  Preheader,
                                  ExitingBlock,
                                  ExitBlock,
                                  std::move(Polls),
                                  std::move(ExitValues),
                                  std::move(DeadExitPhis)};
}

bool EmptyLoopPollRemovalPlan::stillStructurallyValid(LoopInfo &LI,
                                                      DominatorTree &DT) const {
  if (LI.getLoopFor(L->getHeader()) != L ||
      L->getLoopPreheader() != Preheader ||
      L->getExitingBlock() != ExitingBlock ||
      L->getUniqueExitBlock() != ExitBlock || !L->isLCSSAForm(DT) ||
      !L->hasDedicatedExits() ||
      ExitBlock->getSinglePredecessor() != ExitingBlock)
    return false;
  for (CallInst *P : Polls)
    if (!P->getParent() || !L->contains(P) || !isSafepointPoll(*P))
      return false;
  for (const EmptyLoopExitValueCheck &ExitValue : ExitValues)
    if (ExitValue.Phi->getNumIncomingValues() != 1 ||
        ExitValue.Phi->getIncomingBlock(0) != ExitingBlock ||
        ExitValue.Phi->getIncomingValue(0) != ExitValue.OriginalValue)
      return false;
  for (PHINode *Phi : DeadExitPhis)
    if (Phi->getNumIncomingValues() != 1 ||
        Phi->getIncomingBlock(0) != ExitingBlock)
      return false;
  return true;
}

void applyEmptyLoopPollRemovalPlan(const EmptyLoopPollRemovalPlan &Plan,
                                   LoopInfo &LI, DominatorTree &DT,
                                   ScalarEvolution &SE) {
  SCEVExpander Rewriter(SE, "jeandle-empty-loop-delete");
  for (const EmptyLoopExitValueCheck &ExitValue : Plan.ExitValues) {
    Value *Replacement =
        Rewriter.expandCodeFor(ExitValue.ExitValue, ExitValue.Phi->getType(),
                               Plan.Preheader->getTerminator());
    ExitValue.Phi->setIncomingValue(0, Replacement);
  }
  for (PHINode *Phi : Plan.DeadExitPhis)
    Phi->setIncomingValue(0, PoisonValue::get(Phi->getType()));

  LLVM_DEBUG(dbgs() << "  loop-deletion-prep: deleting "
                    << Plan.L->getHeader()->getName() << " and "
                    << Plan.Polls.size() << " poll(s)\n");
  for (CallInst *P : Plan.Polls)
    P->eraseFromParent();
  deleteDeadLoop(Plan.L, &DT, &SE, &LI);
}

static bool completeLoopPollDeletion(Function &F, LoopInfo &LI,
                                     DominatorTree &DT, ScalarEvolution &SE,
                                     SafepointPollEliminationMode Mode,
                                     bool DeferEmptyLoopDeletion) {
  SmallVector<Loop *, 8> Loops(LI.getLoopsInPreorder());
  SmallPtrSet<Loop *, 8> DeferredEmptyLoops;
  if (DeferEmptyLoopDeletion) {
    for (Loop *L : Loops) {
      if (DeferredEmptyLoops.contains(L))
        continue;
      if (!buildEmptyLoopPollRemovalPlan(L, LI, DT, SE))
        continue;
      for (Loop *Nested : L->getLoopsInPreorder())
        DeferredEmptyLoops.insert(Nested);
    }
  }

  SmallPtrSet<Loop *, 8> HasSfpt;
  RequiredPolls Required;
  for (Loop *L : llvm::reverse(Loops))
    analyzeLoop(*L, LI, DT, HasSfpt, Required);

  bool Changed = false;
  for (Loop *L : llvm::reverse(Loops)) {
    if (DeferredEmptyLoops.contains(L))
      continue;
    Changed |= deleteLoopPolls(*L, LI, DT, SE, HasSfpt, Required, Mode);
  }
  return Changed;
}

} // namespace

bool llvm::jeandle::isEmptyLoopPollDeletionCandidate(Loop &L, LoopInfo &LI,
                                                     DominatorTree &DT,
                                                     ScalarEvolution &SE) {
  return buildEmptyLoopPollRemovalPlan(&L, LI, DT, SE).has_value();
}

void SafepointPollElimination::printPipeline(
    raw_ostream &OS, function_ref<StringRef(StringRef)> MapClassName2PassName) {
  static_cast<PassInfoMixin<SafepointPollElimination> *>(this)->printPipeline(
      OS, MapClassName2PassName);
  OS << '<';
  switch (Mode) {
  case SafepointPollEliminationMode::Early:
    OS << "early";
    break;
  case SafepointPollEliminationMode::AfterStripMining:
    OS << "after-strip-mining";
    break;
  case SafepointPollEliminationMode::LoopDeletionPrep:
    OS << "loop-deletion-prep";
    break;
  }
  if (DeferEmptyLoopDeletion)
    OS << ";defer-empty-loop-deletion";
  OS << '>';
}

PreservedAnalyses SafepointPollElimination::run(Function &F,
                                                FunctionAnalysisManager &AM) {
  if (!jeandle::isSafepointEliminationEnabled() ||
      !jeandle::isRootJavaMethodFunction(F))
    return PreservedAnalyses::all();

  LLVM_DEBUG(dbgs() << "poll-elimination<" << modeName(Mode) << "> running on "
                    << F.getName() << "\n");

  auto &LI = AM.getResult<LoopAnalysis>(F);
  ReversePostOrderTraversal<const Function *> RPOT(&F);
  bool HasIrreducibleCFG = containsIrreducibleCFG<const BasicBlock *>(RPOT, LI);
  if (HasIrreducibleCFG) {
    LLVM_DEBUG(dbgs() << "poll-elimination<" << modeName(Mode)
                      << ">: irreducible CFG in " << F.getName()
                      << ", all polls preserved\n");
    return PreservedAnalyses::all();
  }

  if (Mode == SafepointPollEliminationMode::LoopDeletionPrep) {
    auto &DT = AM.getResult<DominatorTreeAnalysis>(F);
    auto &SE = AM.getResult<ScalarEvolutionAnalysis>(F);
    // Deleting one empty region can expose another empty region in its parent.
    // Iterate to a fixpoint; each application strictly removes a loop nest.
    bool Changed = false;
    bool LocalChanged = true;
    while (LocalChanged) {
      LocalChanged = false;
      SmallVector<Loop *, 8> Loops(LI.getLoopsInPreorder());
      SmallVector<EmptyLoopPollRemovalPlan, 4> Plans;
      SmallPtrSet<Loop *, 8> PlannedLoops;
      for (Loop *L : Loops) {
        if (PlannedLoops.contains(L))
          continue;
        if (auto Plan = buildEmptyLoopPollRemovalPlan(L, LI, DT, SE)) {
          for (Loop *Nested : L->getLoopsInPreorder())
            PlannedLoops.insert(Nested);
          Plans.push_back(std::move(*Plan));
        }
      }

      for (EmptyLoopPollRemovalPlan &Plan : Plans) {
        if (!Plan.stillStructurallyValid(LI, DT))
          continue;
        applyEmptyLoopPollRemovalPlan(Plan, LI, DT, SE);
        Changed = LocalChanged = true;
      }
    }
    return Changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
  }

  if (Mode == SafepointPollEliminationMode::AfterStripMining) {
    auto &DT = AM.getResult<DominatorTreeAnalysis>(F);
    auto &SE = AM.getResult<ScalarEvolutionAnalysis>(F);
    bool Changed =
        completeLoopPollDeletion(F, LI, DT, SE, Mode, DeferEmptyLoopDeletion);
    return Changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
  }

  assert(Mode == SafepointPollEliminationMode::Early);
  bool Changed = false;
  for (BasicBlock &BB : F)
    if (!LI.getLoopFor(&BB))
      Changed |= collapseRedundantPolls(BB);

  if (!jeandle::isStripMiningEnabled()) {
    auto &DT = AM.getResult<DominatorTreeAnalysis>(F);
    auto &SE = AM.getResult<ScalarEvolutionAnalysis>(F);
    Changed |=
        completeLoopPollDeletion(F, LI, DT, SE, Mode, DeferEmptyLoopDeletion);
  }

  return Changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
}
