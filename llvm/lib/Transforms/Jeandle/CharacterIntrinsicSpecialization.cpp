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
#include "llvm/Analysis/AliasAnalysis.h"
#include "llvm/Analysis/LazyValueInfo.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Jeandle/CharacterIntrinsics.h"
#include "llvm/IR/Jeandle/VMConstants.h"
#include "llvm/IR/Module.h"
#include "llvm/Transforms/Jeandle/JeandleTransformUtils.h"
#include "llvm/Transforms/Utils/Local.h"

using namespace llvm;
using namespace llvm::jeandle;

namespace {
void expand(CallInst &Call, CharacterIntrinsic Op, unsigned Count) {
  VMConstants Layout = VMConstants::fromModule(*Call.getModule());
  IRBuilder<> B(&Call);
  BasicBlock *Head = Call.getParent();
  BasicBlock *Exit =
      Head->splitBasicBlock(Call.getIterator(), "character.result");
  Head->getTerminator()->eraseFromParent();
  PHINode *Result = PHINode::Create(B.getInt32Ty(), Count + 1,
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
  for (unsigned I = 0; I != Count; ++I) {
    Value *Index = B.CreateAdd(Call.getArgOperand(1), B.getInt32(I));
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
    Result->addIncoming(B.getInt32(I), B.GetInsertBlock());
    B.CreateCondBr(Invalid, Exit, Next);
    B.SetInsertPoint(Next);
    if (!Op.Scan) {
      Value *DI = B.CreateAdd(Call.getArgOperand(3), B.getInt32(I));
      Value *DP = Address(Call.getArgOperand(2), DI, 1, false);
      auto *Store =
          B.CreateAlignedStore(B.CreateTrunc(C, B.getInt8Ty()), DP, Align(1));
      Store->setAtomic(AtomicOrdering::Unordered);
    }
  }
  Result->addIncoming(B.getInt32(Count), B.GetInsertBlock());
  B.CreateBr(Exit);
  Call.replaceAllUsesWith(Result);
  Call.eraseFromParent();
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
    if (!Count || Count->isNegative() ||
        Count->getZExtValue() > CharacterScalarLimit)
      continue;
    if (Count->getZExtValue() > 8) {
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
    expand(*Call, P.Op, P.Count);
  }
  return Plans.empty() ? PreservedAnalyses::all() : PreservedAnalyses::none();
}
