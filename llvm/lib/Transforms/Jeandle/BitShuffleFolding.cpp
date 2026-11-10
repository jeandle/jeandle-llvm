//===- BitShuffleFolding.cpp - Fold Java bitshuffle identities
//--------------===//
//
// Copyright (c) 2026, The Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/BitShuffleFolding.h"

#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/AssumptionCache.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/IntrinsicsX86.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/PatternMatch.h"
#include "llvm/IR/ValueHandle.h"
#include "llvm/Transforms/Utils/Local.h"

using namespace llvm;
using namespace llvm::PatternMatch;

namespace {

bool isBitShuffle(const IntrinsicInst &II) {
  if (II.isMustTailCall() || II.hasOperandBundles())
    return false;
  switch (II.getIntrinsicID()) {
  case Intrinsic::x86_bmi_pext_32:
  case Intrinsic::x86_bmi_pext_64:
  case Intrinsic::x86_bmi_pdep_32:
  case Intrinsic::x86_bmi_pdep_64:
    return true;
  default:
    return false;
  }
}

Value *foldBitShuffle(IntrinsicInst &II, AssumptionCache &AC,
                      DominatorTree &DT) {
  Intrinsic::ID IID = II.getIntrinsicID();
  bool IsPext =
      IID == Intrinsic::x86_bmi_pext_32 || IID == Intrinsic::x86_bmi_pext_64;
  Value *Input = II.getArgOperand(0);
  Value *Mask = II.getArgOperand(1);
  IRBuilder<> Builder(&II);

  if (!IsPext && match(Input, m_AllOnes()))
    return Mask;

  Intrinsic::ID InverseIID;
  switch (IID) {
  case Intrinsic::x86_bmi_pext_32:
    InverseIID = Intrinsic::x86_bmi_pdep_32;
    break;
  case Intrinsic::x86_bmi_pext_64:
    InverseIID = Intrinsic::x86_bmi_pdep_64;
    break;
  case Intrinsic::x86_bmi_pdep_32:
    InverseIID = Intrinsic::x86_bmi_pext_32;
    break;
  case Intrinsic::x86_bmi_pdep_64:
    InverseIID = Intrinsic::x86_bmi_pext_64;
    break;
  default:
    llvm_unreachable("Expected PEXT or PDEP");
  }

  if (auto *Inner = dyn_cast<IntrinsicInst>(Input)) {
    // An independently observed inner result can constrain undef choices.
    // Single use also avoids retaining the inner call alongside a new AND.
    if (isBitShuffle(*Inner) && Inner->getIntrinsicID() == InverseIID &&
        Inner->hasOneUse() && Inner->getArgOperand(1) == Mask) {
      Value *Source = Inner->getArgOperand(0);
      if (!IsPext)
        return Builder.CreateAnd(Source, Mask);

      // PEXT(M, M) is the low popcount(M) bits, including M == 0 or -1.
      // Stabilize a possibly undef mask before duplicating it. Choosing this
      // same mask for both original calls is a refinement, also for poison.
      if (!isGuaranteedNotToBeUndef(Mask, &AC, &II, &DT))
        Mask = Builder.CreateFreeze(Mask);
      Value *LowMask = Builder.CreateIntrinsic(IID, {}, {Mask, Mask});
      return Builder.CreateAnd(Source, LowMask);
    }
  }

  Value *Shift;
  bool IsSingleBit = match(Mask, m_OneUse(m_Shl(m_One(), m_Value(Shift))));
  if (!IsSingleBit &&
      !match(Mask, m_OneUse(m_Shl(m_AllOnes(), m_Value(Shift)))))
    return nullptr;

  // Reuse the count: out-of-range LLVM shifts remain poison, and frontend
  // Java count masking stays intact. Single use prevents an independently
  // selected undef count from disagreeing with an observed mask. Do not copy
  // the mask's wrap flags onto an operation with a different left operand.
  if (IsPext) {
    Value *Shifted = Builder.CreateLShr(Input, Shift);
    return IsSingleBit ? Builder.CreateAnd(Shifted, 1) : Shifted;
  }
  if (IsSingleBit)
    Input = Builder.CreateAnd(Input, 1);
  return Builder.CreateShl(Input, Shift);
}

} // namespace

PreservedAnalyses BitShuffleFoldingPass::run(Function &F,
                                             FunctionAnalysisManager &FAM) {
  Module *M = F.getParent();
  if (!M || !M->getNamedMetadata(jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();

  SmallVector<WeakTrackingVH, 16> Worklist;
  auto Enqueue = [&](Value *V) {
    if (auto *II = dyn_cast<IntrinsicInst>(V))
      if (II->getFunction() == &F && isBitShuffle(*II))
        Worklist.push_back(II);
  };
  for (Instruction &I : instructions(F))
    Enqueue(&I);
  if (Worklist.empty())
    return PreservedAnalyses::all();

  AssumptionCache &AC = FAM.getResult<AssumptionAnalysis>(F);
  DominatorTree &DT = FAM.getResult<DominatorTreeAnalysis>(F);
  bool Changed = false;
  while (!Worklist.empty()) {
    auto *II = dyn_cast_or_null<IntrinsicInst>(Worklist.pop_back_val());
    if (!II || !isBitShuffle(*II))
      continue;
    Value *Replacement = foldBitShuffle(*II, AC, DT);
    if (!Replacement)
      continue;

    for (User *U : II->users())
      Enqueue(U);
    II->replaceAllUsesWith(Replacement);
    // Recursive deletion can expose single-use producers and invalidate queued
    // instructions. Weak handles follow replacements and null out on deletion.
    RecursivelyDeleteTriviallyDeadInstructions(
        II, nullptr, nullptr, [&](Value *Dead) {
          for (Value *Operand : cast<Instruction>(Dead)->operands()) {
            auto *Producer = dyn_cast<Instruction>(Operand);
            if (!Producer || Producer->getFunction() != &F)
              continue;
            Enqueue(Producer);
            for (User *U : Producer->users())
              Enqueue(U);
          }
        });
    Changed = true;
  }

  // Every successful fold decreases the number of bitshuffle calls. New
  // low-mask PEXT calls cannot match an inverse composition, so revisiting
  // affected users/producers terminates without a whole-function rescan.
  return Changed ? PreservedAnalyses::allInSet<CFGAnalyses>()
                 : PreservedAnalyses::all();
}
