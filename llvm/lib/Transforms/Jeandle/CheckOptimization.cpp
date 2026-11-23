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
#include "llvm/Analysis/GuardUtils.h"
#include "llvm/Analysis/Jeandle/PartialEscapeUtils.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/OptimizationRemarkEmitter.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Jeandle/JeandleUtils.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
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
#include "llvm/Transforms/Utils/LCSSA.h"
#include "llvm/Transforms/Utils/Local.h"
#include "llvm/Transforms/Utils/LoopSimplify.h"

using namespace llvm;

static cl::opt<bool> OptimizeChecks(
    "jeandle-optimize-checks", cl::init(true), cl::Hidden,
    cl::desc("Optimize Java null and array bounds checks before strip mining"));

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
  if (!HasCheck && !HasArrayLength && !Guards &&
      (!OptimizeChecks || !HasIntegerCompare))
    return PreservedAnalyses::all();
  auto &LI = FAM.getResult<LoopAnalysis>(F);
  bool HasLoops = !LI.empty();
  if (!HasCheck && !HasArrayLength && !Guards &&
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
      Prepare.addPass(IndVarSimplifyPass());
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
  return PA;
}
