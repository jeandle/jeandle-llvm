//===- CopySignStoreLowering.cpp - Lower copySign stores -----------------===//
//
// Copyright (c) 2026, The Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/CopySignStoreLowering.h"

#include "llvm/ADT/APInt.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"
#include "llvm/TargetParser/Triple.h"

using namespace llvm;

namespace {

bool shouldLowerCopySign(const IntrinsicInst &II) {
  if (II.getIntrinsicID() != Intrinsic::copysign || II.isMustTailCall() ||
      II.hasOperandBundles() || II.use_empty())
    return false;

  Type *Ty = II.getType();
  if (!Ty->isFloatTy() && !Ty->isDoubleTy())
    return false;

  auto *Magnitude = dyn_cast<BitCastInst>(II.getArgOperand(0));
  // The rewrite only pays off when both operands can stay in the GPR file:
  // values produced by integer arithmetic (bitcasts from integers) and loads,
  // which the backend can feed from either register bank. Values computed in
  // floating point live in XMM, and O3 canonicalizes the integer pattern back
  // to llvm.copysign while their sources stay FP-typed, so lowering those
  // shapes is dead work before O3 and a pessimization for the post-O3 rerun.
  auto IsLoadOrIntCast = [](Value *V) {
    if (isa<LoadInst>(V))
      return true;
    auto *Cast = dyn_cast<BitCastInst>(V);
    return Cast && Cast->getSrcTy()->isIntegerTy();
  };
  if (!IsLoadOrIntCast(II.getArgOperand(0)) ||
      !IsLoadOrIntCast(II.getArgOperand(1)))
    return false;
  bool IntegerInputs = Magnitude && Magnitude->getSrcTy()->isIntegerTy() &&
                       !isa<LoadInst>(Magnitude->getOperand(0));
  bool HasStore = false;
  bool HasIntegerUse = false;
  for (const Use &U : II.uses()) {
    if (isa<StoreInst>(U.getUser()) && U.getOperandNo() == 0) {
      HasStore = true;
      continue;
    }
    if (auto *Cast = dyn_cast<BitCastInst>(U.getUser())) {
      if (!IntegerInputs || !Cast->getType()->isIntegerTy())
        return false;
      HasIntegerUse = true;
      continue;
    }
    auto *CB = dyn_cast<CallBase>(U.getUser());
    if (!CB || !CB->isBundleOperand(&U) ||
        !CB->isOperandBundleOfType(LLVMContext::OB_deopt, U.getOperandNo()))
      return false;
  }
  return HasStore || HasIntegerUse;
}

} // namespace

PreservedAnalyses CopySignStoreLoweringPass::run(Function &F,
                                                 FunctionAnalysisManager &FAM) {
  Module *M = F.getParent();
  if (!M || !M->getNamedMetadata(jeandle::Metadata::JavaMethodCompilation) ||
      !M->getTargetTriple().isX86())
    return PreservedAnalyses::all();

  bool Changed = false;
  for (Instruction &I : make_early_inc_range(instructions(F))) {
    auto *II = dyn_cast<IntrinsicInst>(&I);
    if (!II || !shouldLowerCopySign(*II))
      continue;

    Type *Ty = II->getType();
    unsigned Width = Ty->isFloatTy() ? 32 : 64;
    IntegerType *BitsTy = IntegerType::get(F.getContext(), Width);
    IRBuilder<> Builder(II);
    Value *Magnitude = Builder.CreateBitCast(II->getArgOperand(0), BitsTy,
                                             "copysign.magnitude.bits");
    Value *Sign = Builder.CreateBitCast(II->getArgOperand(1), BitsTy,
                                        "copysign.sign.bits");
    Magnitude = Builder.CreateAnd(
        Magnitude, ConstantInt::get(BitsTy, APInt::getSignedMaxValue(Width)),
        "copysign.magnitude");
    Sign = Builder.CreateAnd(
        Sign, ConstantInt::get(BitsTy, APInt::getSignMask(Width)),
        "copysign.sign");
    Value *Bits = Builder.CreateOr(Magnitude, Sign, "copysign.bits");
    Value *Result = Builder.CreateBitCast(Bits, Ty, "copysign.value");

    // Each operand is consumed once, preserving undef/poison choices without
    // a freeze. Deopt bundle operands keep the same FP value and type. The
    // original stores retain their ordering and metadata; O3 can combine the
    // result bitcast into their stored representation.
    II->replaceAllUsesWith(Result);
    II->eraseFromParent();
    Changed = true;
  }

  return Changed ? PreservedAnalyses::allInSet<CFGAnalyses>()
                 : PreservedAnalyses::all();
}
