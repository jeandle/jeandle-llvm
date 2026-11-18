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
#include "llvm/Analysis/OptimizationRemarkEmitter.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
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

// Once the original condition folds to true there is no check left to
// optimize. Remove the unused widening permission before PEA so its failure
// state does not make object identity appear observable on a dead path.
PreservedAnalyses CheckPreparation::run(Function &F,
                                        FunctionAnalysisManager &FAM) {
  if (F.isDeclaration() || !F.getParent()->getNamedMetadata(
                               jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();
  bool Changed = false;
  for (BasicBlock &BB : F) {
    auto *BI = dyn_cast<BranchInst>(BB.getTerminator());
    if (!BI || !BI->isConditional() ||
        !BI->getSuccessor(1)->getTerminatingDeoptimizeCall())
      continue;
    auto *WC = dyn_cast<IntrinsicInst>(BI->getCondition());
    if (!WC ||
        WC->getIntrinsicID() != Intrinsic::experimental_widenable_condition)
      continue;
    BI->setCondition(ConstantInt::getTrue(F.getContext()));
    if (WC->use_empty())
      WC->eraseFromParent();
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
  for (BasicBlock &BB : F) {
    HasCheck |= BB.getTerminatingDeoptimizeCall() != nullptr;
    for (Instruction &I : BB) {
      if (auto *II = dyn_cast<IntrinsicInst>(&I))
        Guards +=
            II->getIntrinsicID() == Intrinsic::experimental_widenable_condition;
      if (auto *CB = dyn_cast<CallBase>(&I))
        if (Function *Callee = CB->getCalledFunction())
          HasCheck |= Callee->getName() == "jeandle.arraylength";
    }
  }
  if (!HasCheck && !Guards)
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
  if (OptimizeChecks && WithinBudget) {
    LoopPassManager Prepare;
    LICMOptions ConservativeLICM;
    ConservativeLICM.AllowSpeculation = false;
    Prepare.addPass(LICMPass(ConservativeLICM));
    Prepare.addPass(LoopRotatePass(true, false));
    Prepare.addPass(IndVarSimplifyPass());
    Prepare.addPass(SimpleLoopUnswitchPass(true));
    PM.addPass(createFunctionToLoopPassAdaptor(std::move(Prepare), true));
    PM.addPass(ArrayLengthOptimization());
    addCleanup(PM);
    PM.addPass(GuardWideningPass());
    LoopPassManager Predication;
    Predication.addPass(LoopPredicationPass());
    Predication.addPass(LICMPass(LICMOptions()));
    Predication.addPass(SimpleLoopUnswitchPass(true));
    PM.addPass(createFunctionToLoopPassAdaptor(std::move(Predication), true));
    PM.addPass(GuardWideningPass());
  }
  // Widenable conditions are temporary optimization permissions, never part
  // of the final loop checks or implicit-null-check recognition.
  PM.addPass(LowerWidenableConditionPass());
  addCleanup(PM);
  if (OptimizeChecks && F.getInstructionCount() <= 10000) {
    // Lowering and unswitching expose non-null loop entries that were still
    // guarded when array lengths were prepared above.
    PM.addPass(ArrayLengthOptimization());
    PM.addPass(IRCEPass());
    addCleanup(PM);
    PM.addPass(LoopSimplifyPass());
    PM.addPass(LCSSAPass());
    PM.addPass(ArrayLengthOptimization());
    PM.addPass(AffineCheckVersioning());
    addCleanup(PM);
  }
  PM.addPass(LoopSimplifyPass());
  PM.addPass(LCSSAPass());
  // A nested pass manager invalidates each child's analyses immediately.
  PreservedAnalyses PA = PM.run(F, FAM);

  for (BasicBlock &BB : F) {
    auto *BI = dyn_cast<BranchInst>(BB.getTerminator());
    if (!BI || !BI->isConditional())
      continue;
    BI->setMetadata(LLVMContext::MD_make_implicit, nullptr);
    auto *Cmp = dyn_cast<ICmpInst>(BI->getCondition());
    if (!Cmp || !Cmp->isEquality() ||
        !Cmp->getOperand(0)->getType()->isPointerTy())
      continue;
    if (!isa<ConstantPointerNull>(Cmp->getOperand(0)) &&
        !isa<ConstantPointerNull>(Cmp->getOperand(1)))
      continue;
    unsigned NullSucc = Cmp->getPredicate() == ICmpInst::ICMP_EQ ? 0 : 1;
    if (BI->getSuccessor(NullSucc)->getTerminatingDeoptimizeCall())
      BI->setMetadata(LLVMContext::MD_make_implicit,
                      MDNode::get(F.getContext(), {}));
  }
  return PA;
}
