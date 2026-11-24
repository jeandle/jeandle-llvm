//===- CheckOptimization.cpp - Java checks --------------------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/CheckOptimization.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/Analysis/AssumptionCache.h"
#include "llvm/Analysis/DomTreeUpdater.h"
#include "llvm/Analysis/GuardUtils.h"
#include "llvm/Analysis/Jeandle/PartialEscapeUtils.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/OptimizationRemarkEmitter.h"
#include "llvm/Analysis/SimplifyQuery.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Jeandle/JeandleUtils.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/PatternMatch.h"
#include "llvm/IR/ValueHandle.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Transforms/InstCombine/InstCombine.h"
#include "llvm/Transforms/Jeandle/AffineCheckVersioning.h"
#include "llvm/Transforms/Jeandle/ArrayLengthOptimization.h"
#include "llvm/Transforms/Scalar/ConstraintElimination.h"
#include "llvm/Transforms/Scalar/EarlyCSE.h"
#include "llvm/Transforms/Scalar/GuardWidening.h"
#include "llvm/Transforms/Scalar/IndVarSimplify.h"
#include "llvm/Transforms/Scalar/InductiveRangeCheckElimination.h"
#include "llvm/Transforms/Scalar/LICM.h"
#include "llvm/Transforms/Scalar/LoopPassManager.h"
#include "llvm/Transforms/Scalar/LoopPredication.h"
#include "llvm/Transforms/Scalar/LoopRotation.h"
#include "llvm/Transforms/Scalar/LowerWidenableCondition.h"
#include "llvm/Transforms/Scalar/SimpleLoopUnswitch.h"
#include "llvm/Transforms/Scalar/SimplifyCFG.h"
#include "llvm/Transforms/Utils/Cloning.h"
#include "llvm/Transforms/Utils/LCSSA.h"
#include "llvm/Transforms/Utils/Local.h"
#include "llvm/Transforms/Utils/LoopSimplify.h"

using namespace llvm;
using namespace llvm::PatternMatch;

static cl::opt<bool> OptimizeChecks(
    "jeandle-optimize-checks", cl::init(true), cl::Hidden,
    cl::desc("Optimize Java null and array bounds checks before strip mining"));

PreservedAnalyses NullCheckElimination::run(Function &F,
                                            FunctionAnalysisManager &FAM) {
  if (!OptimizeChecks || F.isDeclaration() || F.getInstructionCount() > 10000 ||
      !F.getParent()->getNamedMetadata(
          jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();

  struct Edge {
    BasicBlock *Check, *Pred, *Pass;
  };
  SmallVector<Edge, 16> Edges;
  auto &DT = FAM.getResult<DominatorTreeAnalysis>(F);
  auto &AC = FAM.getResult<AssumptionAnalysis>(F);
  for (BasicBlock &BB : F) {
    auto *BI = dyn_cast<BranchInst>(BB.getTerminator());
    auto *Cmp = BI && BI->isConditional()
                    ? dyn_cast<ICmpInst>(BI->getCondition())
                    : nullptr;
    if (!Cmp || !Cmp->isEquality() || Cmp->getParent() != &BB ||
        Cmp->getNextNode() != BI || BB.isEHPad() || BB.hasAddressTaken() ||
        BB.size() > 8 || pred_size(&BB) < 2)
      continue;
    Value *Pointer = nullptr;
    if (isa<ConstantPointerNull>(Cmp->getOperand(0)))
      Pointer = Cmp->getOperand(1);
    else if (isa<ConstantPointerNull>(Cmp->getOperand(1)))
      Pointer = Cmp->getOperand(0);
    if (!Pointer || !Pointer->getType()->isPointerTy())
      continue;
    auto *PN = dyn_cast<PHINode>(Pointer);
    if (!PN || PN->getParent() != &BB || PN->getNumIncomingValues() > 16)
      continue;
    BasicBlock *Pass =
        BI->getSuccessor(Cmp->getPredicate() == ICmpInst::ICMP_NE ? 0 : 1);
    if (Pass == &BB || BI->getSuccessor(0) == BI->getSuccessor(1))
      continue;

    bool Duplicable = true;
    for (Instruction &I : BB) {
      if (&I == BI)
        continue;
      if (!isa<PHINode>(I) &&
          (I.mayHaveSideEffects() || I.mayReadOrWriteMemory())) {
        Duplicable = false;
        break;
      }
      // Decode is a pure, non-throwing JavaOp at this point. Other calls may
      // carry convergence, deoptimization or duplication obligations.
      if (auto *CB = dyn_cast<CallBase>(&I)) {
        auto *Callee = CB->getCalledFunction();
        if (!Callee || Callee->getName() != "jeandle.decode_heap_oop" ||
            CB->hasOperandBundles() || CB->isConvergent() ||
            CB->cannotDuplicate() || !CB->doesNotAccessMemory()) {
          Duplicable = false;
          break;
        }
      }
      for (Use &U : I.uses()) {
        auto *User = dyn_cast<Instruction>(U.getUser());
        if (User && User->getParent() == &BB)
          continue;
        auto *Phi = dyn_cast<PHINode>(User);
        if (!Phi || Phi->getIncomingBlock(U) != &BB ||
            (Phi->getParent() != BI->getSuccessor(0) &&
             Phi->getParent() != BI->getSuccessor(1))) {
          Duplicable = false;
          break;
        }
      }
      if (!Duplicable)
        break;
    }
    if (!Duplicable)
      continue;

    for (unsigned Idx = 0; Idx < PN->getNumIncomingValues(); ++Idx) {
      BasicBlock *Pred = PN->getIncomingBlock(Idx);
      // Only bypass checks on existing natural-loop backedges. This cannot
      // create an additional loop entry, unlike general header threading.
      if (Pred == &BB || !isa<BranchInst>(Pred->getTerminator()) ||
          !DT.isReachableFromEntry(Pred) || !DT.dominates(Pass, Pred) ||
          count(successors(Pred), &BB) != 1)
        continue;
      SimplifyQuery Q(F.getDataLayout(), &DT, &AC, Pred->getTerminator());
      if (isKnownNonZero(PN->getIncomingValue(Idx), Q))
        Edges.push_back({&BB, Pred, Pass});
      if (Edges.size() == 16)
        break;
    }
    if (Edges.size() == 16)
      break;
  }
  if (Edges.empty())
    return PreservedAnalyses::all();

  // All proofs precede mutation. Cloning/remapping preserves the expressions
  // on each edge; no memory facts are inferred across calls or fresh loads.
  DomTreeUpdater DTU(DT, DomTreeUpdater::UpdateStrategy::Eager);
  for (auto [BB, Pred, Pass] : Edges) {
    // Another threaded check may have split either of these original edges.
    if (pred_size(BB) < 2 || count(successors(Pred), BB) != 1 ||
        count(successors(BB), Pass) != 1)
      continue;
    ValueToValueMapTy VMap;
    auto *BI = cast<BranchInst>(BB->getTerminator());
    auto *Cmp = cast<ICmpInst>(BI->getCondition());
    BasicBlock *Split =
        DuplicateInstructionsInSplitBetween(BB, Pred, Cmp, VMap, DTU);
    // The comparison is not cloned; its result is known on the success edge.
    VMap[Cmp] = ConstantInt::get(Cmp->getType(),
                                 Cmp->getPredicate() == ICmpInst::ICMP_NE);
    for (PHINode &Phi : Pass->phis()) {
      Value *V = Phi.getIncomingValueForBlock(BB);
      if (Value *Mapped = VMap.lookup(V))
        V = Mapped;
      Phi.addIncoming(V, Split);
    }
    BB->removePredecessor(Split, /*KeepOneInputPHIs=*/true);
    Split->getTerminator()->setSuccessor(0, Pass);
    DTU.applyUpdates({{DominatorTree::Delete, Split, BB},
                      {DominatorTree::Insert, Split, Pass}});
  }
  return PreservedAnalyses::none();
}

static bool foldClampedRangeChecks(Function &F, FunctionAnalysisManager &FAM) {
  SmallVector<std::pair<ICmpInst *, bool>, 8> Folded;
  for (BasicBlock &BB : F) {
    for (Instruction &I : BB) {
      auto *Cmp = dyn_cast<ICmpInst>(&I);
      if (!Cmp || Cmp->use_empty() ||
          !Cmp->getOperand(0)->getType()->isIntegerTy())
        continue;
      Value *Index = Cmp->getOperand(0), *Length = Cmp->getOperand(1);
      ICmpInst::Predicate Pred = Cmp->getPredicate();
      if (Pred == ICmpInst::ICMP_UGT || Pred == ICmpInst::ICMP_ULE) {
        std::swap(Index, Length);
        Pred = ICmpInst::getSwappedPredicate(Pred);
      }
      if (Pred != ICmpInst::ICMP_ULT && Pred != ICmpInst::ICMP_UGE)
        continue;
      Value *Lower, *Upper;
      if (!match(Index, m_SMin(m_Value(Lower), m_Value(Upper))))
        continue;
      auto IsLastIndex = [&](Value *V) {
        return match(V, m_c_Add(m_Specific(Length), m_AllOnes())) ||
               match(V, m_Sub(m_Specific(Length), m_One()));
      };
      if (!IsLastIndex(Upper)) {
        std::swap(Lower, Upper);
        if (!IsLastIndex(Upper))
          continue;
      }
      auto &DT = FAM.getResult<DominatorTreeAnalysis>(F);
      auto &AC = FAM.getResult<AssumptionAnalysis>(F);
      const DataLayout &DL = F.getDataLayout();
      SimplifyQuery Q(DL, &DT, &AC, Cmp);
      // For positive signed length, length - 1 cannot wrap and is nonnegative.
      // Signed min with a nonnegative operand is then in [0, length), even if
      // the expression clamped by that operand used wrapping Java arithmetic.
      if (!isKnownNonNegative(Lower, Q) ||
          (!isKnownPositive(Length, Q) &&
           isImpliedByDomCondition(ICmpInst::ICMP_SGT, Length,
                                   ConstantInt::get(Length->getType(), 0), Cmp,
                                   DL) != true))
        continue;
      Folded.emplace_back(Cmp, Pred == ICmpInst::ICMP_ULT);
    }
  }
  for (auto [Cmp, Result] : Folded)
    Cmp->replaceAllUsesWith(ConstantInt::get(Cmp->getType(), Result));
  return !Folded.empty();
}

static void addCleanup(FunctionPassManager &PM) {
  PM.addPass(EarlyCSEPass());
  PM.addPass(InstCombinePass());
  PM.addPass(ConstraintEliminationPass());
  PM.addPass(SimplifyCFGPass());
}

static bool hasLoopCheck(Function &F, LoopInfo &LI) {
  SmallPtrSet<Loop *, 8> HasExit, HasMultipleExits;
  for (BasicBlock &BB : F) {
    Loop *L = LI.getLoopFor(&BB);
    auto *BI = dyn_cast<BranchInst>(BB.getTerminator());
    if (L && BI && BI->isConditional() &&
        L->contains(BI->getSuccessor(0)) != L->contains(BI->getSuccessor(1)) &&
        !HasExit.insert(L).second)
      HasMultipleExits.insert(L);
  }
  // A lone exiting comparison controls the loop; it is not an additional
  // range check. Leave such loops to the normal loop pipeline.
  for (BasicBlock &BB : F) {
    Loop *L = LI.getLoopFor(&BB);
    auto *BI = dyn_cast<BranchInst>(BB.getTerminator());
    if (!HasMultipleExits.contains(L) || &BB == L->getLoopLatch() || !BI ||
        !BI->isConditional() ||
        L->contains(BI->getSuccessor(0)) == L->contains(BI->getSuccessor(1)))
      continue;
    SmallVector<Value *, 8> Worklist{BI->getCondition()};
    SmallPtrSet<Value *, 32> Seen;
    while (!Worklist.empty()) {
      Value *V = Worklist.pop_back_val();
      if (!Seen.insert(V).second)
        continue;
      // An exhausted discovery budget is a candidate, not proof that the
      // expression contains no check. The transforms have their own budgets.
      if (Seen.size() > 32)
        return true;
      if (auto *Cmp = dyn_cast<ICmpInst>(V)) {
        if (Cmp->getOperand(0)->getType()->isIntegerTy())
          return true;
      } else if (auto *I = dyn_cast<Instruction>(V)) {
        if (I->getType()->isIntegerTy(1) &&
            (isa<BinaryOperator, SelectInst, PHINode>(I)))
          append_range(Worklist, I->operands());
      }
    }
  }
  return false;
}

// The object pool represents direct virtual identities, but cannot select a
// virtual identity conditionally. Do not introduce synthetic failures whose
// frame state would force such an identity to materialize before PEA.
static bool hasConditionalAllocation(const Value *V) {
  V = getUnderlyingObject(V);
  if (!isa<PHINode, SelectInst>(V))
    return false;
  SmallVector<const Value *, 8> Worklist{V};
  SmallPtrSet<const Value *, 32> Visited;
  constexpr unsigned Budget = 32;
  while (!Worklist.empty()) {
    const Value *Object = getUnderlyingObject(Worklist.pop_back_val());
    if (!Visited.insert(Object).second)
      continue;
    if (Visited.size() > Budget)
      return true;
    if (auto *CB = dyn_cast<CallBase>(Object)) {
      if (jeandle::pea::isJeandleAllocation(CB))
        return true;
    } else if (auto *SI = dyn_cast<SelectInst>(Object)) {
      Worklist.push_back(SI->getTrueValue());
      Worklist.push_back(SI->getFalseValue());
    } else if (auto *PN = dyn_cast<PHINode>(Object)) {
      if (PN->getNumIncomingValues() > Budget)
        return true;
      append_range(Worklist, PN->incoming_values());
    }
  }
  return false;
}

static bool hasConditionalVirtualState(const CallInst &Deopt) {
  auto Bundle = Deopt.getOperandBundle(LLVMContext::OB_deopt);
  if (!Bundle)
    return false;
  return any_of(Bundle->Inputs, [](const Use &U) {
    return jeandle::isWideOopType(U->getType()) &&
           hasConditionalAllocation(U.get());
  });
}

// Drop widening permissions that have no useful check left or would prevent
// conditional virtual state from being represented by PEA. Keep permissions
// visible until here: adding them after frame-state simplification could
// invalidate facts used to simplify the original failure state.
PreservedAnalyses CheckPreparation::run(Function &F,
                                        FunctionAnalysisManager &FAM) {
  if (F.isDeclaration() || !F.getParent()->getNamedMetadata(
                               jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();
  bool Changed = false;
  for (BasicBlock &BB : F) {
    auto *BI = dyn_cast<BranchInst>(BB.getTerminator());
    Value *Condition, *WC;
    BasicBlock *Pass, *Fail;
    if (!BI || !parseWidenableBranch(BI, Condition, WC, Pass, Fail))
      continue;
    auto *Deopt = Fail->getTerminatingDeoptimizeCall();
    if (!Deopt || (Condition != ConstantInt::getTrue(F.getContext()) &&
                   !hasConditionalVirtualState(*Deopt)))
      continue;
    Value *OldCondition = BI->getCondition();
    WeakTrackingVH Widenable(WC);
    BI->setCondition(Condition);
    RecursivelyDeleteTriviallyDeadInstructions(OldCondition);
    if (Widenable && Widenable->use_empty())
      cast<Instruction>(Widenable)->eraseFromParent();
    Changed = true;
  }
  return Changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
}

PreservedAnalyses CheckOptimization::run(Function &F,
                                         FunctionAnalysisManager &FAM) {
  if (F.isDeclaration() || !F.getParent()->getNamedMetadata(
                               jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();
  bool Changed = foldClampedRangeChecks(F, FAM);
  if (Changed)
    FAM.invalidate(F, PreservedAnalyses::none());
  unsigned Guards = 0;
  bool HasCheck = false;
  bool HasArrayLength = false;
  bool HasIntegerCompare = false;
  for (BasicBlock &BB : F) {
    HasCheck |= BB.getTerminatingDeoptimizeCall() != nullptr;
    for (Instruction &I : BB) {
      if (auto *Cmp = dyn_cast<ICmpInst>(&I))
        HasIntegerCompare |= Cmp->getOperand(0)->getType()->isIntegerTy();
      if (auto *II = dyn_cast<IntrinsicInst>(&I))
        Guards +=
            II->getIntrinsicID() == Intrinsic::experimental_widenable_condition;
      if (auto *CB = dyn_cast<CallBase>(&I))
        if (Function *Callee = CB->getCalledFunction())
          HasArrayLength |= Callee->getName() == "jeandle.arraylength";
    }
  }
  if (!Changed && !HasCheck && !HasArrayLength && !Guards &&
      (!OptimizeChecks || !HasIntegerCompare))
    return PreservedAnalyses::all();
  auto &LI = FAM.getResult<LoopAnalysis>(F);
  bool HasLoops = !LI.empty();
  if (!Changed && !HasCheck && !HasArrayLength && !Guards &&
      (!OptimizeChecks || !HasLoops || !hasLoopCheck(F, LI)))
    return PreservedAnalyses::all();

  FunctionPassManager PM;
  addCleanup(PM);
  // GuardWidening has quadratic cost. Large functions retain inexpensive
  // scalar cleanup; LLVM's own loop profitability limits apply within this
  // additional method-size and guard-count budget.
  bool WithinBudget = Guards <= 256 && F.getInstructionCount() <= 10000;
  if (OptimizeChecks && !WithinBudget) {
    FAM.getResult<OptimizationRemarkEmitterAnalysis>(F).emit([&]() {
      return OptimizationRemarkMissed("jeandle-check-optimization", "Budget",
                                      &F)
             << "skipping expensive check transforms: function or guard budget "
                "exceeded";
    });
  }
  if (OptimizeChecks && WithinBudget &&
      (HasLoops || HasArrayLength || Guards)) {
    if (HasLoops) {
      LoopPassManager Prepare;
      LICMOptions ConservativeLICM;
      ConservativeLICM.AllowSpeculation = false;
      Prepare.addPass(LICMPass(ConservativeLICM));
      Prepare.addPass(LoopRotatePass(true, false));
      Prepare.addPass(IndVarSimplifyPass(/*WidenIndVars=*/false));
      Prepare.addPass(SimpleLoopUnswitchPass(true));
      PM.addPass(createFunctionToLoopPassAdaptor(std::move(Prepare), true));
    }
    if (HasArrayLength)
      PM.addPass(ArrayLengthOptimization());
    addCleanup(PM);
    if (Guards)
      PM.addPass(GuardWideningPass());
    if (HasLoops) {
      LoopPassManager Predication;
      if (Guards)
        Predication.addPass(LoopPredicationPass());
      Predication.addPass(LICMPass(LICMOptions()));
      Predication.addPass(SimpleLoopUnswitchPass(true));
      PM.addPass(createFunctionToLoopPassAdaptor(std::move(Predication), true));
    }
    if (Guards)
      PM.addPass(GuardWideningPass());
  }
  // Widenable conditions are temporary optimization permissions, never part
  // of the final loop checks or implicit-null-check recognition.
  if (Guards) {
    PM.addPass(LowerWidenableConditionPass());
    addCleanup(PM);
  }
  if (OptimizeChecks && HasLoops && F.getInstructionCount() <= 10000) {
    // Lowering and unswitching expose non-null loop entries that were still
    // guarded when array lengths were prepared above.
    if (HasArrayLength)
      PM.addPass(ArrayLengthOptimization());
    PM.addPass(IRCEPass());
    addCleanup(PM);
    PM.addPass(LoopSimplifyPass());
    PM.addPass(LCSSAPass());
    if (HasArrayLength)
      PM.addPass(ArrayLengthOptimization());
    PM.addPass(AffineCheckVersioning());
    addCleanup(PM);
  }
  if (HasLoops) {
    PM.addPass(LoopSimplifyPass());
    PM.addPass(LCSSAPass());
  }
  // A nested pass manager invalidates each child's analyses immediately.
  PreservedAnalyses PA = PM.run(F, FAM);

  for (BasicBlock &BB : F) {
    auto *BI = dyn_cast<BranchInst>(BB.getTerminator());
    if (!BI)
      continue;
    bool WasImplicit = BI->getMetadata(LLVMContext::MD_make_implicit);
    BI->setMetadata(LLVMContext::MD_make_implicit, nullptr);
    if (!BI->isConditional())
      continue;
    auto *Cmp = dyn_cast<ICmpInst>(BI->getCondition());
    if (!Cmp || !Cmp->isEquality() ||
        !Cmp->getOperand(0)->getType()->isPointerTy())
      continue;
    if (!isa<ConstantPointerNull>(Cmp->getOperand(0)) &&
        !isa<ConstantPointerNull>(Cmp->getOperand(1)))
      continue;
    unsigned NullSucc = Cmp->getPredicate() == ICmpInst::ICMP_EQ ? 0 : 1;
    // Rebuilding a null branch must not grant a permission withheld by the
    // producer. The deopt carries positive permission across guard widening;
    // hot handlers and failures without feedback retain explicit branches.
    auto *Deopt = BI->getSuccessor(NullSucc)->getTerminatingDeoptimizeCall();
    if (WasImplicit ||
        (Deopt && Deopt->hasFnAttr(jeandle::Metadata::ImplicitNullCheck)))
      BI->setMetadata(LLVMContext::MD_make_implicit,
                      MDNode::get(F.getContext(), {}));
  }
  return Changed ? PreservedAnalyses::none() : PA;
}
