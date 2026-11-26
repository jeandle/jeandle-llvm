//===- CharacterIntrinsicSpecialization.cpp - Bounded encoding/scanning
//----===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/CharacterIntrinsicSpecialization.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/Analysis/AliasAnalysis.h"
#include "llvm/Analysis/Jeandle/PartialEscapeUtils.h"
#include "llvm/Analysis/LazyValueInfo.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Jeandle/CharacterIntrinsics.h"
#include "llvm/IR/Jeandle/VMConstants.h"
#include "llvm/IR/Module.h"
#include "llvm/Transforms/Jeandle/JeandleTransformUtils.h"
#include "llvm/Transforms/Jeandle/PartialEscapeIterative.h"
#include "llvm/Transforms/Jeandle/PrePEAAllocationUnrollHints.h"
#include "llvm/Transforms/Utils/Local.h"
#include "llvm/Transforms/Utils/UnrollLoop.h"

using namespace llvm;
using namespace llvm::jeandle;

namespace {
void expand(CallInst &Call, CharacterIntrinsic Op, unsigned Count,
            bool UseLoop) {
  VMConstants Layout = VMConstants::fromModule(*Call.getModule());
  IRBuilder<> B(&Call);
  BasicBlock *Head = Call.getParent();
  BasicBlock *Exit =
      Head->splitBasicBlock(Call.getIterator(), "character.result");
  Head->getTerminator()->eraseFromParent();
  PHINode *Result = PHINode::Create(B.getInt32Ty(), UseLoop ? 2 : Count + 1,
                                    "character.prefix", Call.getIterator());
  B.SetInsertPoint(Head);
  auto Address = [&](Value *Array, Value *Index, unsigned Width,
                     bool CharArray) {
    int64_t Base = Layout.arrayBaseOffsetFor(CharArray ? JBasicType::Char
                                                       : JBasicType::Byte);
    Value *Offset = B.CreateAdd(
        B.CreateMul(B.CreateZExt(Index, B.getInt64Ty()), B.getInt64(Width)),
        B.getInt64(Base));
    return B.CreateGEP(B.getInt8Ty(), Array, Offset, "character.cell");
  };
  auto Load = [&](Value *P, unsigned Bits) -> Value * {
    auto *L = B.CreateAlignedLoad(B.getIntNTy(Bits), P, Align(Bits / 8));
    L->setAtomic(AtomicOrdering::Unordered);
    return L;
  };
  BasicBlock *Loop = nullptr;
  PHINode *LoopIndex = nullptr;
  if (UseLoop) {
    Loop = BasicBlock::Create(Call.getContext(), "character.loop",
                              Call.getFunction(), Exit);
    B.CreateBr(Loop);
    B.SetInsertPoint(Loop);
    LoopIndex = B.CreatePHI(B.getInt32Ty(), 2, "character.index");
    LoopIndex->addIncoming(B.getInt32(0), Head);
  }
  for (unsigned I = 0; I != (UseLoop ? 1 : Count); ++I) {
    Value *Offset = UseLoop ? static_cast<Value *>(LoopIndex) : B.getInt32(I);
    Value *Index = B.CreateAdd(Call.getArgOperand(1), Offset);
    Value *P = Address(Call.getArgOperand(0), Index, Op.Scan ? 1 : 2,
                       !Op.Scan && !Op.SourceBytes);
    Value *C;
    Value *Invalid;
    if (Op.Scan) {
      C = Load(P, 8);
      Invalid = B.CreateICmpSLT(C, B.getInt8(0));
    } else {
      if (!Op.SourceBytes) {
        C = Load(P, 16);
      } else {
        Value *First = B.CreateZExt(Load(P, 8), B.getInt16Ty());
        Value *Second =
            B.CreateZExt(Load(B.CreateGEP(B.getInt8Ty(), P, B.getInt64(1)), 8),
                         B.getInt16Ty());
        bool LE = Call.getModule()->getDataLayout().isLittleEndian();
        C = B.CreateOr(LE ? First : Second,
                       B.CreateShl(LE ? Second : First, 8));
      }
      Invalid = B.CreateICmpUGT(C, B.getInt16(Op.ASCII ? 127 : 255));
    }
    BasicBlock *Next = BasicBlock::Create(Call.getContext(), "character.valid",
                                          Call.getFunction(), Exit);
    Result->addIncoming(Offset, B.GetInsertBlock());
    B.CreateCondBr(Invalid, Exit, Next);
    B.SetInsertPoint(Next);
    if (!Op.Scan) {
      Value *DI = B.CreateAdd(Call.getArgOperand(3), Offset);
      Value *DP = Address(Call.getArgOperand(2), DI, 1, false);
      auto *Store =
          B.CreateAlignedStore(B.CreateTrunc(C, B.getInt8Ty()), DP, Align(1));
      Store->setAtomic(AtomicOrdering::Unordered);
    }
  }
  Result->addIncoming(B.getInt32(Count), B.GetInsertBlock());
  if (UseLoop) {
    Value *NextIndex = B.CreateAdd(LoopIndex, B.getInt32(1));
    LoopIndex->addIncoming(NextIndex, B.GetInsertBlock());
    B.CreateCondBr(B.CreateICmpULT(NextIndex, B.getInt32(Count)), Loop, Exit);
  } else {
    B.CreateBr(Exit);
  }
  Call.replaceAllUsesWith(Result);
  Call.eraseFromParent();
}

std::optional<uint64_t> expansionCost(CallBase &Call, CharacterIntrinsic Op,
                                      unsigned Count, ConstantInt *SourceOffset,
                                      ConstantInt *DestinationOffset,
                                      const TargetTransformInfo &TTI) {
  // Estimate the emitted accesses without changing the caller or its analyses.
  // Loop control and unsimplified address arithmetic make this conservative
  // for straight-line expansion, where constant indices fold immediately.
  Function *Probe =
      Function::Create(Call.getFunctionType(), GlobalValue::PrivateLinkage,
                       "jeandle.character.cost", Call.getModule());
  IRBuilder<> B(BasicBlock::Create(Call.getContext(), "entry", Probe));
  SmallVector<Value *, 7> Arguments;
  for (unsigned I = 0; I != Call.arg_size(); ++I) {
    Value *Argument = Call.getArgOperand(I);
    Arguments.push_back(isa<Constant>(Argument) ? Argument : Probe->getArg(I));
  }
  if (SourceOffset)
    Arguments[1] = SourceOffset;
  Arguments[Op.countIndex()] = B.getInt32(Count);
  if (!Op.Scan && DestinationOffset)
    Arguments[3] = DestinationOffset;
  CallInst *Candidate = B.CreateCall(Call.getCalledFunction(), Arguments);
  Candidate->setCallingConv(Call.getCallingConv());
  B.CreateRet(Candidate);
  expand(*Candidate, Op, Count, /*UseLoop=*/true);

  std::optional<uint64_t> Cost;
  {
    DominatorTree DT(*Probe);
    LoopInfo LI(DT);
    if (LI.getTopLevelLoops().size() == 1) {
      SmallPtrSet<const Value *, 1> EphemeralValues;
      UnrollCostEstimator Estimate(*LI.begin(), TTI, EphemeralValues,
                                   /*BEInsns=*/0);
      if (Estimate.canUnroll()) {
        TargetTransformInfo::UnrollingPreferences Preferences{};
        Preferences.BEInsns = 0;
        Cost = Estimate.getUnrolledLoopSize(Preferences, Count);
      }
    }
  }
  Probe->eraseFromParent();
  return Cost;
}
} // namespace

PreservedAnalyses
CharacterIntrinsicSpecialization::run(Function &F,
                                      FunctionAnalysisManager &AM) {
  if (F.getName().starts_with("jeandle."))
    return PreservedAnalyses::all();
  struct Plan {
    CallBase *Call;
    CharacterIntrinsic Op;
    unsigned Count;
    SmallVector<std::pair<unsigned, ConstantInt *>, 4> Constants;
  };
  SmallVector<Plan, 8> Plans;
  LazyValueInfo *LVI = nullptr;
  uint64_t RemainingCost = PrePEAFullUnrollFunctionBudget;
  for (Instruction &I : instructions(F)) {
    auto *CB = dyn_cast<CallBase>(&I);
    if (!CB || CB->hasOperandBundles() ||
        (isa<CallInst>(CB) && cast<CallInst>(CB)->isMustTailCall()))
      continue;
    auto Op = decodeCharacterIntrinsic(*CB);
    if (!Op)
      continue;
    auto Constant = [&](unsigned Arg) -> ConstantInt * {
      Value *V = CB->getArgOperand(Arg);
      if (auto *C = dyn_cast<ConstantInt>(V))
        return C;
      if (!LVI)
        LVI = &AM.getResult<LazyValueAnalysis>(F);
      return dyn_cast_or_null<ConstantInt>(LVI->getConstant(V, CB));
    };
    ConstantInt *Count = Constant(Op->countIndex());
    if (!Count || Count->isNegative())
      continue;
    if (Count->getZExtValue() > CharacterScalarLimit) {
      unsigned MaxCount = getPrePEAFullUnrollMaxCount();
      if (!ExpandLargeArrays || !isPEAEnabled() ||
          Count->getZExtValue() > MaxCount)
        continue;
      const LoopInfo &LI = AM.getResult<LoopAnalysis>(F);
      if (!pea::hasNonEscapingLocalArray(CB->getArgOperand(0), LI, MaxCount,
                                         PrePEAFullUnrollFunctionBudget) &&
          (Op->Scan ||
           !pea::hasNonEscapingLocalArray(CB->getArgOperand(2), LI, MaxCount,
                                          PrePEAFullUnrollFunctionBudget)))
        continue;
      auto Cost = expansionCost(*CB, *Op, Count->getZExtValue(), Constant(1),
                                Op->Scan ? nullptr : Constant(3),
                                AM.getResult<TargetIRAnalysis>(F));
      if (!Cost || *Cost > PrePEAFullUnrollLoopBudget || *Cost > RemainingCost)
        continue;
      RemainingCost -= *Cost;
    } else if (Count->getZExtValue() > 8) {
      const LoopInfo &LI = AM.getResult<LoopAnalysis>(F);
      BatchAAResults AA(AM.getResult<AAManager>(F));
      if (!hasScalarArrayOpportunity(CB->getArgOperand(0), LI, AA) &&
          (Op->Scan ||
           !hasScalarArrayOpportunity(CB->getArgOperand(2), LI, AA)))
        continue;
    }
    Plan P{CB, *Op, static_cast<unsigned>(Count->getZExtValue()), {}};
    for (unsigned Arg : {1u, Op->countIndex(), Op->Scan ? 1u : 3u})
      if (!isa<ConstantInt>(CB->getArgOperand(Arg)))
        if (ConstantInt *C = Constant(Arg))
          P.Constants.emplace_back(Arg, C);
    Plans.push_back(std::move(P));
  }
  // Complete contextual queries before expansion invalidates CFG analyses.
  for (Plan &P : Plans) {
    for (auto [Arg, C] : P.Constants)
      P.Call->setArgOperand(Arg, C);
    CallInst *Call = dyn_cast<CallInst>(P.Call);
    if (!Call)
      Call = changeToCall(cast<InvokeInst>(P.Call));
    expand(*Call, P.Op, P.Count, /*UseLoop=*/false);
  }
  return Plans.empty() ? PreservedAnalyses::all() : PreservedAnalyses::none();
}
