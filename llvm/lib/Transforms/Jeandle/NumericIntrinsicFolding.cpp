//===- NumericIntrinsicFolding.cpp - Fold numeric consumers ---------------===//
//
// Copyright (c) 2026, The Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/NumericIntrinsicFolding.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/AssumptionCache.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/PatternMatch.h"
#include "llvm/IR/ValueHandle.h"
#include "llvm/Support/KnownBits.h"
#include "llvm/Transforms/Utils/Local.h"

using namespace llvm;
using namespace llvm::PatternMatch;

namespace {

Value *foldRound(CallInst &Call, AssumptionCache &AC, DominatorTree &DT) {
  Function *Callee = Call.getCalledFunction();
  if (!Callee || Call.isMustTailCall() || Call.hasOperandBundles() ||
      Callee->getFnAttribute(jeandle::Attribute::LowerPhase)
              .getValueAsString() != "1" ||
      Call.getFunctionType()->isVarArg() || Call.arg_size() != 1)
    return nullptr;
  Type *FPTy = Call.getArgOperand(0)->getType();
  unsigned ResultWidth;
  if (Callee->getName() == "jeandle.round.double" && FPTy->isDoubleTy())
    ResultWidth = 64;
  else if (Callee->getName() == "jeandle.round.float" && FPTy->isFloatTy())
    ResultWidth = 32;
  else
    return nullptr;
  if (!Call.getType()->isIntegerTy(ResultWidth))
    return nullptr;

  auto *Cast = dyn_cast<CastInst>(Call.getArgOperand(0));
  if (!Cast || (Cast->getOpcode() != Instruction::SIToFP &&
                Cast->getOpcode() != Instruction::UIToFP))
    return nullptr;
  Value *Source = Cast->getOperand(0);
  if (!Source->getType()->isIntegerTy())
    return nullptr;
  const DataLayout &DL = Call.getModule()->getDataLayout();
  unsigned Precision = APFloat::semanticsPrecision(FPTy->getFltSemantics());
  bool Signed = Cast->getOpcode() == Instruction::SIToFP;
  unsigned MagnitudeBits =
      Signed
          ? Source->getType()->getIntegerBitWidth() -
                ComputeNumSignBits(Source, DL, &AC, &Call, &DT)
          : computeKnownBits(Source, DL, &AC, &Call, &DT).countMaxActiveBits();
  // Precision proves that integer-to-FP does not round. The separate signed
  // destination bound excludes saturation (also for unsigned source values).
  if (MagnitudeBits > Precision || MagnitudeBits >= ResultWidth)
    return nullptr;
  IRBuilder<> Builder(&Call);
  return Signed ? Builder.CreateSExtOrTrunc(Source, Call.getType())
                : Builder.CreateZExtOrTrunc(Source, Call.getType());
}

// Match the value form emitted for Math.signum. A stable input makes all
// observations agree, including the NaN payload returned by the special arm.
Value *getSignumInput(Value *V, AssumptionCache &AC, DominatorTree &DT) {
  auto *Sel = dyn_cast<SelectInst>(V);
  if (!Sel || (!Sel->getType()->isFloatTy() && !Sel->getType()->isDoubleTy()) ||
      Sel->getFastMathFlags().any() || Sel->hasPoisonGeneratingAnnotations())
    return nullptr;
  Value *X = Sel->getTrueValue();
  auto *Cmp = dyn_cast<FCmpInst>(Sel->getCondition());
  if (!Cmp || Cmp->getFastMathFlags().any() ||
      Cmp->hasPoisonGeneratingAnnotations() ||
      Cmp->getPredicate() != CmpInst::FCMP_UEQ ||
      !((Cmp->getOperand(0) == X && match(Cmp->getOperand(1), m_AnyZeroFP())) ||
        (Cmp->getOperand(1) == X && match(Cmp->getOperand(0), m_AnyZeroFP()))))
    return nullptr;
  auto *Copy = dyn_cast<IntrinsicInst>(Sel->getFalseValue());
  if (!Copy || Copy->getIntrinsicID() != Intrinsic::copysign ||
      Copy->hasOperandBundles() || Copy->isMustTailCall() ||
      Copy->getFastMathFlags().any() ||
      Copy->hasPoisonGeneratingAnnotations() ||
      Copy->getRetNoFPClass() != fcNone ||
      Copy->getParamNoFPClass(0) != fcNone ||
      Copy->getParamNoFPClass(1) != fcNone ||
      !match(Copy->getArgOperand(0), m_SpecificFP(1.0)) ||
      Copy->getArgOperand(1) != X ||
      !isGuaranteedNotToBeUndefOrPoison(X, &AC, Sel, &DT))
    return nullptr;
  return X;
}

Value *foldSignumCompare(FCmpInst &Cmp, AssumptionCache &AC,
                         DominatorTree &DT) {
  Value *Signum = Cmp.getOperand(0);
  auto *C = dyn_cast<ConstantFP>(Cmp.getOperand(1));
  CmpInst::Predicate Pred = Cmp.getPredicate();
  if (!C) {
    C = dyn_cast<ConstantFP>(Signum);
    Signum = Cmp.getOperand(1);
    Pred = CmpInst::getSwappedPredicate(Pred);
  }
  if (!C)
    return nullptr;
  Value *X = getSignumInput(Signum, AC, DT);
  if (!X)
    return nullptr;
  if (C->isZero() && (Pred == CmpInst::FCMP_OGT || Pred == CmpInst::FCMP_OLT)) {
    // The same ordered predicate excludes NaN and both signed zeros.
  } else if (Pred == CmpInst::FCMP_OEQ && C->isExactlyValue(1.0)) {
    Pred = CmpInst::FCMP_OGT;
  } else if (Pred == CmpInst::FCMP_OEQ && C->isExactlyValue(-1.0)) {
    Pred = CmpInst::FCMP_OLT;
  } else {
    return nullptr;
  }
  return IRBuilder<>(&Cmp).CreateFCmp(Pred, X,
                                      ConstantFP::get(X->getType(), 0.0));
}

Value *foldSignumSign(CallInst &Call, AssumptionCache &AC, DominatorTree &DT) {
  auto *Copy = dyn_cast<IntrinsicInst>(&Call);
  if (!Copy || Copy->getIntrinsicID() != Intrinsic::copysign ||
      Copy->isMustTailCall() || Copy->hasOperandBundles())
    return nullptr;
  Value *Signum = Copy->getArgOperand(1);
  if (auto *Freeze = dyn_cast<FreezeInst>(Signum))
    Signum = Freeze->getOperand(0);
  Value *X = getSignumInput(Signum, AC, DT);
  if (!X)
    return nullptr;
  // signum preserves the sign of every class, including NaNs and signed zero.
  // Reusing its copysign also handles a nested signum whose guards have
  // already been merged by scalar simplification.
  auto *Inner = cast<IntrinsicInst>(cast<SelectInst>(Signum)->getFalseValue());
  if (Inner->getArgOperand(0) == Copy->getArgOperand(0))
    return Inner;
  return IRBuilder<>(&Call).CreateBinaryIntrinsic(Intrinsic::copysign,
                                                  Copy->getArgOperand(0), X);
}

} // namespace

PreservedAnalyses
NumericIntrinsicFoldingPass::run(Function &F, FunctionAnalysisManager &FAM) {
  if (!F.getParent()->getNamedMetadata(
          jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();
  SmallVector<WeakTrackingVH, 16> Candidates;
  for (Instruction &I : instructions(F)) {
    if (auto *Call = dyn_cast<CallInst>(&I)) {
      Function *Callee = Call->getCalledFunction();
      if (Callee && (Callee->getName() == "jeandle.round.float" ||
                     Callee->getName() == "jeandle.round.double" ||
                     Callee->getIntrinsicID() == Intrinsic::copysign))
        Candidates.push_back(&I);
    } else if (isa<FCmpInst>(I) ||
               (isa<SelectInst>(I) &&
                (I.getType()->isFloatTy() || I.getType()->isDoubleTy()))) {
      Candidates.push_back(&I);
    }
  }
  if (Candidates.empty())
    return PreservedAnalyses::all();
  AssumptionCache &AC = FAM.getResult<AssumptionAnalysis>(F);
  DominatorTree &DT = FAM.getResult<DominatorTreeAnalysis>(F);

  bool Changed = false;
  for (WeakTrackingVH &Handle : Candidates) {
    auto *I = dyn_cast_or_null<Instruction>(Handle);
    if (!I)
      continue;
    Value *Replacement = nullptr;
    if (auto *Call = dyn_cast<CallInst>(I)) {
      Replacement = foldRound(*Call, AC, DT);
      if (!Replacement)
        Replacement = foldSignumSign(*Call, AC, DT);
    } else if (auto *Cmp = dyn_cast<FCmpInst>(I))
      Replacement = foldSignumCompare(*Cmp, AC, DT);
    else if (Value *Input = getSignumInput(I, AC, DT)) {
      Value *Inner = Input;
      if (auto *Freeze = dyn_cast<FreezeInst>(Inner))
        Inner = Freeze->getOperand(0);
      if (getSignumInput(Inner, AC, DT))
        Replacement = Inner;
    }
    if (!Replacement)
      continue;
    I->replaceAllUsesWith(Replacement);
    // Round JavaOps are pure and terminating. Signum only contains pure
    // expressions; unrelated value consumers retain their original result.
    if (isa<CallInst>(I))
      I->eraseFromParent();
    else
      RecursivelyDeleteTriviallyDeadInstructions(I);
    Changed = true;
  }
  return Changed ? PreservedAnalyses::allInSet<CFGAnalyses>()
                 : PreservedAnalyses::all();
}
