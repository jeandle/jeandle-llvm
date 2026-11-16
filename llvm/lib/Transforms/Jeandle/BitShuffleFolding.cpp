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

#define DEBUG_TYPE "bit-shuffle-folding"
#include "llvm/Transforms/Utils/InstructionWorklist.h"

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

  // These masks always select a contiguous low-bit prefix. Reuse the mask
  // itself, including any Java-masked count and any independently observed use.
  if (match(Mask, m_LShr(m_AllOnes(), m_Value())) ||
      match(Mask, m_Sub(m_Shl(m_One(), m_Value()), m_One())) ||
      match(Mask, m_Add(m_Shl(m_One(), m_Value()), m_AllOnes())) ||
      match(Mask, m_Not(m_Shl(m_AllOnes(), m_Value()))))
    return Builder.CreateAnd(Input, Mask);

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
    // A retained inner result constrains undef choices in both operands.
    // PDEP(PEXT(X,M),M) still saves a call with multiple users when those
    // operands are stable. The reverse identity creates another PEXT, so it
    // needs the single-use restriction for profitability as well.
    if (isBitShuffle(*Inner) && Inner->getIntrinsicID() == InverseIID &&
        Inner->getArgOperand(1) == Mask &&
        (Inner->hasOneUse() ||
         (!IsPext && isGuaranteedNotToBeUndef(Mask, &AC, &II, &DT) &&
          isGuaranteedNotToBeUndef(Inner->getArgOperand(0), &AC, &II, &DT)))) {
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

  InstructionWorklist Worklist;
  auto Enqueue = [&](Value *V) {
    if (auto *II = dyn_cast<IntrinsicInst>(V))
      if (II->getFunction() == &F && isBitShuffle(*II))
        Worklist.push(II);
  };
  for (Instruction &I : instructions(F))
    Enqueue(&I);
  if (Worklist.isEmpty())
    return PreservedAnalyses::all();

  AssumptionCache &AC = FAM.getResult<AssumptionAnalysis>(F);
  DominatorTree &DT = FAM.getResult<DominatorTreeAnalysis>(F);
  bool Changed = false;

  // Testing whether any selected bit is set does not require compressing
  // those bits. Keep a shared PEXT result rather than adding another test.
  SmallVector<WeakTrackingVH, 4> ZeroTests;
  for (Instruction &I : instructions(F)) {
    auto *Cmp = dyn_cast<ICmpInst>(&I);
    if (!Cmp || !Cmp->isEquality())
      continue;
    Value *Input = Cmp->getOperand(0);
    if (match(Input, m_Zero()))
      Input = Cmp->getOperand(1);
    else if (!match(Cmp->getOperand(1), m_Zero()))
      continue;
    auto *Pext = dyn_cast<IntrinsicInst>(Input);
    if (Pext && isBitShuffle(*Pext) && Pext->hasOneUse() &&
        (Pext->getIntrinsicID() == Intrinsic::x86_bmi_pext_32 ||
         Pext->getIntrinsicID() == Intrinsic::x86_bmi_pext_64))
      ZeroTests.push_back(Cmp);
  }
  for (WeakTrackingVH &Handle : ZeroTests) {
    auto *Cmp = dyn_cast_or_null<ICmpInst>(Handle);
    if (!Cmp)
      continue;
    auto *Pext = dyn_cast<IntrinsicInst>(Cmp->getOperand(0));
    if (!Pext)
      Pext = cast<IntrinsicInst>(Cmp->getOperand(1));
    IRBuilder<> Builder(Cmp);
    Value *Masked = Builder.CreateAnd(
        Pext->getArgOperand(0), Pext->getArgOperand(1), "compress.masked");
    Value *Replacement = Builder.CreateICmp(
        Cmp->getPredicate(), Masked, ConstantInt::get(Masked->getType(), 0));
    Cmp->replaceAllUsesWith(Replacement);
    RecursivelyDeleteTriviallyDeadInstructions(
        Cmp, nullptr, nullptr,
        [&](Value *Dead) { Worklist.remove(cast<Instruction>(Dead)); });
    Changed = true;
  }

  // popcount(compress(x, m)) == popcount(x & m): the extracted bits are
  // exactly the masked bits. Rewrite the popcount input before the worklist
  // runs so a now-dead single-use compress is collected with its operands.
  // popcount(expand(x, m)) has no such form -- it counts the low
  // popcount(m) bits of x, not the masked bits -- and stays untouched.
  SmallVector<std::pair<IntrinsicInst *, IntrinsicInst *>, 4> Popcounts;
  for (Instruction &I : instructions(F)) {
    auto *Cnt = dyn_cast<IntrinsicInst>(&I);
    if (!Cnt || Cnt->getIntrinsicID() != Intrinsic::ctpop ||
        Cnt->isMustTailCall() || Cnt->hasOperandBundles())
      continue;
    auto *Pext = dyn_cast<IntrinsicInst>(Cnt->getArgOperand(0));
    if (!Pext || !isBitShuffle(*Pext) ||
        (Pext->getIntrinsicID() != Intrinsic::x86_bmi_pext_32 &&
         Pext->getIntrinsicID() != Intrinsic::x86_bmi_pext_64))
      continue;
    Popcounts.push_back({Cnt, Pext});
  }
  for (auto [Cnt, Pext] : Popcounts) {
    IRBuilder<> Builder(Cnt);
    Cnt->setArgOperand(0, Builder.CreateAnd(Pext->getArgOperand(0),
                                            Pext->getArgOperand(1),
                                            "compress.masked"));
    RecursivelyDeleteTriviallyDeadInstructions(
        Pext, nullptr, nullptr,
        [&](Value *Dead) { Worklist.remove(cast<Instruction>(Dead)); });
    Changed = true;
  }

  while (!Worklist.isEmpty()) {
    auto *II = dyn_cast_or_null<IntrinsicInst>(Worklist.removeOne());
    if (!II || !isBitShuffle(*II))
      continue;
    Value *Replacement = foldBitShuffle(*II, AC, DT);
    if (!Replacement)
      continue;

    for (User *U : II->users())
      Enqueue(U);
    II->replaceAllUsesWith(Replacement);
    // The callback runs before operands are dropped. Keep weak handles until
    // recursive deletion finishes, including when an operand occurs twice or
    // is itself deleted. Remove deleted instructions from the worklist before
    // their addresses can be reused.
    SmallVector<WeakTrackingVH, 16> AffectedOperands;
    RecursivelyDeleteTriviallyDeadInstructions(
        II, nullptr, nullptr, [&](Value *Dead) {
          Worklist.remove(cast<Instruction>(Dead));
          for (Value *Operand : cast<Instruction>(Dead)->operands()) {
            auto *Producer = dyn_cast<Instruction>(Operand);
            if (!Producer || Producer->getFunction() != &F)
              continue;
            AffectedOperands.push_back(Producer);
          }
        });
    // Only a single remaining use can expose a one-use fold. Inspecting that
    // use is constant time even for operands shared by many bitshuffle calls.
    for (WeakTrackingVH &Operand : AffectedOperands)
      if (Value *V = Operand)
        if (V->hasOneUse())
          Enqueue(*V->user_begin());
    Changed = true;
  }

  // Every successful fold decreases the number of bitshuffle calls. New
  // low-mask PEXT calls cannot match an inverse composition, so revisiting
  // affected users terminates without a whole-function rescan.
  return Changed ? PreservedAnalyses::allInSet<CFGAnalyses>()
                 : PreservedAnalyses::all();
}
