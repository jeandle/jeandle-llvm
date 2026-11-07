//===- StringIntrinsicSpecialization.cpp - Bounded string expansion
//--------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/StringIntrinsicSpecialization.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/Analysis/AliasAnalysis.h"
#include "llvm/Analysis/Jeandle/PartialEscapeUtils.h"
#include "llvm/Analysis/LazyValueInfo.h"
#include "llvm/Analysis/Loads.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Jeandle/StringIntrinsics.h"
#include "llvm/IR/Jeandle/VMConstants.h"
#include "llvm/IR/Module.h"
#include "llvm/Transforms/Jeandle/JeandleTransformUtils.h"
#include "llvm/Transforms/Utils/Local.h"

using namespace llvm;
using namespace llvm::jeandle;

namespace {

// Byte-backed UTF16 uses the two byte cells of StringUTF16.getChar/putChar.
// Keeping those cells explicit also lets PEA model symbolic byte arrays.
// Char arrays retain their indivisible i16 accesses.
class Expansion {
  CallInst &Call;
  StringIntrinsic Op;
  VMConstants Layout;
  IRBuilder<> B;
  BasicBlock *Exit;
  PHINode *Result = nullptr;

  BasicBlock *block(StringRef Name) {
    return BasicBlock::Create(Call.getContext(), Name, Call.getFunction(),
                              Exit);
  }
  Value *address(Value *Array, Value *Index, unsigned Bytes, bool CharArray) {
    int64_t Base = Layout.arrayBaseOffsetFor(CharArray ? JBasicType::Char
                                                       : JBasicType::Byte);
    Value *Offset =
        B.CreateMul(B.CreateZExt(Index, B.getInt64Ty()), B.getInt64(Bytes));
    Offset = B.CreateAdd(Offset, B.getInt64(Base));
    return B.CreateGEP(B.getInt8Ty(), Array, Offset, "string.cell");
  }
  Value *loadCell(Value *Ptr, unsigned Bits) {
    auto *L = B.CreateAlignedLoad(B.getIntNTy(Bits), Ptr, Align(Bits / 8),
                                  "string.load");
    L->setAtomic(AtomicOrdering::Unordered);
    return L;
  }
  void storeCell(Value *V, Value *Ptr) {
    auto *S = B.CreateAlignedStore(
        V, Ptr, Align(V->getType()->getIntegerBitWidth() / 8));
    S->setAtomic(AtomicOrdering::Unordered);
  }
  Value *read(Value *Array, Value *Index, bool UTF16, bool CharArray = false) {
    Value *P = address(Array, Index, UTF16 ? 2 : 1, CharArray);
    if (!UTF16 || CharArray)
      return B.CreateZExt(loadCell(P, UTF16 ? 16 : 8), B.getInt32Ty());
    Value *First = B.CreateZExt(loadCell(P, 8), B.getInt32Ty());
    Value *Second =
        B.CreateZExt(loadCell(B.CreateGEP(B.getInt8Ty(), P, B.getInt64(1)), 8),
                     B.getInt32Ty());
    if (Call.getModule()->getDataLayout().isLittleEndian())
      return B.CreateOr(First, B.CreateShl(Second, 8));
    return B.CreateOr(B.CreateShl(First, 8), Second);
  }
  void write(Value *Array, Value *Index, Value *V, bool UTF16, bool CharArray) {
    Value *P = address(Array, Index, UTF16 ? 2 : 1, CharArray);
    if (!UTF16 || CharArray) {
      storeCell(B.CreateTrunc(V, B.getIntNTy(UTF16 ? 16 : 8)), P);
      return;
    }
    Value *Lo = B.CreateTrunc(V, B.getInt8Ty());
    Value *Hi = B.CreateTrunc(B.CreateLShr(V, 8), B.getInt8Ty());
    bool LE = Call.getModule()->getDataLayout().isLittleEndian();
    storeCell(LE ? Lo : Hi, P);
    storeCell(LE ? Hi : Lo, B.CreateGEP(B.getInt8Ty(), P, B.getInt64(1)));
  }
  void finish(Value *V = nullptr) {
    if (Result)
      Result->addIncoming(V, B.GetInsertBlock());
    B.CreateBr(Exit);
  }
  void finishIf(Value *Cond, Value *V) {
    BasicBlock *Done = block("string.done");
    BasicBlock *Next = block("string.next");
    B.CreateCondBr(Cond, Done, Next);
    B.SetInsertPoint(Done);
    finish(V);
    B.SetInsertPoint(Next);
  }

public:
  Expansion(CallInst &C, StringIntrinsic O)
      : Call(C), Op(O), Layout(VMConstants::fromModule(*C.getModule())), B(&C) {
    BasicBlock *Head = C.getParent();
    Exit = Head->splitBasicBlock(C.getIterator(), "string.result");
    Head->getTerminator()->eraseFromParent();
    if (!C.getType()->isVoidTy())
      Result =
          PHINode::Create(C.getType(), 2, "string.result", C.getIterator());
    B.SetInsertPoint(Head);
  }
  void run() {
    auto A = [&](unsigned I) { return Call.getArgOperand(I); };
    auto N = [&](unsigned I) { return *stringConstantInt(A(I)); };
    switch (Op.Kind) {
    case StringIntrinsicKind::Equals:
    case StringIntrinsicKind::Compare: {
      bool Eq = Op.Kind == StringIntrinsicKind::Equals;
      int64_t Count = Eq ? N(2) : std::min(N(1), N(3));
      for (int64_t I = 0; I < Count; ++I) {
        Value *L = read(A(0), B.getInt32(I), !Eq && Op.leftUTF16());
        Value *R = read(A(Eq ? 1 : 2), B.getInt32(I), !Eq && Op.rightUTF16());
        Value *Diff = B.CreateSub(L, R, "string.difference");
        finishIf(B.CreateICmpNE(Diff, B.getInt32(0)),
                 Eq ? B.getInt32(0) : Diff);
      }
      finish(Eq ? B.getInt32(1) : B.getInt32(N(1) - N(3)));
      break;
    }
    case StringIntrinsicKind::IndexOfChar:
      for (int64_t I = N(2); I < N(3); ++I) {
        Value *C = read(A(0), B.getInt32(I), Op.leftUTF16());
        Value *Ch = Op.leftUTF16()
                        ? A(1)
                        : B.CreateZExt(B.CreateTrunc(A(1), B.getInt8Ty()),
                                       B.getInt32Ty());
        finishIf(B.CreateICmpEQ(C, Ch), B.getInt32(I));
      }
      finish(B.getInt32(-1));
      break;
    case StringIntrinsicKind::IndexOf:
      for (int64_t I = N(4); I <= N(1) - N(3); ++I) {
        BasicBlock *NextCandidate = block("string.candidate");
        for (int64_t J = 0; J < N(3); ++J) {
          Value *L = read(A(0), B.getInt32(I + J), Op.leftUTF16());
          Value *R = read(A(2), B.getInt32(J), Op.rightUTF16());
          BasicBlock *Equal = block("string.equal");
          B.CreateCondBr(B.CreateICmpEQ(L, R), Equal, NextCandidate);
          B.SetInsertPoint(Equal);
        }
        finish(B.getInt32(I));
        B.SetInsertPoint(NextCandidate);
      }
      finish(B.getInt32(-1));
      break;
    case StringIntrinsicKind::CopyUTF16:
    case StringIntrinsicKind::Compress:
    case StringIntrinsicKind::Inflate: {
      bool Inflate = Op.Kind == StringIntrinsicKind::Inflate;
      bool Compress = Op.Kind == StringIntrinsicKind::Compress;
      for (int64_t I = 0; I < N(4); ++I) {
        Value *SI = B.CreateAdd(A(1), B.getInt32(I));
        Value *DI = B.CreateAdd(A(3), B.getInt32(I));
        Value *C = read(A(0), SI, !Inflate, !Inflate && !Op.Layout);
        if (Compress)
          finishIf(B.CreateICmpUGT(C, B.getInt32(255)), B.getInt32(0));
        write(A(2), DI, C, !Compress,
              !Compress && (Inflate ? !Op.Layout : Op.Layout));
      }
      finish(Compress ? B.getInt32(N(4)) : nullptr);
      break;
    }
    }
    if (Result)
      Call.replaceAllUsesWith(Result);
    Call.eraseFromParent();
  }
};

bool specialize(CallBase &CB, bool PreserveScalarConversions) {
  auto Op = decodeStringIntrinsic(CB);
  // Bundles may carry independent frame-state obligations. Keep such calls
  // for the existing lowering/materialization machinery.
  if (!Op || CB.hasOperandBundles() ||
      (isa<CallInst>(CB) && cast<CallInst>(CB).isMustTailCall()))
    return false;
  auto N = [&](unsigned I) { return stringConstantInt(CB.getArgOperand(I)); };
  auto Small = [&](unsigned I) {
    auto C = N(I);
    return C && *C >= 0 && *C <= StringScalarLimit;
  };
  bool Eq = Op->Kind == StringIntrinsicKind::Equals;
  bool Compare = Op->Kind == StringIntrinsicKind::Compare;
  bool Identity = (Eq || (Compare && Op->leftUTF16() == Op->rightUTF16())) &&
                  CB.getArgOperand(0) == CB.getArgOperand(Eq ? 1 : 2);
  if (!Identity) {
    switch (Op->Kind) {
    case StringIntrinsicKind::Equals:
      if (!Small(2))
        return false;
      break;
    case StringIntrinsicKind::Compare:
      if (!Small(1) || !Small(3))
        return false;
      break;
    case StringIntrinsicKind::IndexOfChar:
      if (!N(2) || !N(3) || *N(2) < 0 || *N(3) < *N(2) ||
          *N(3) - *N(2) > StringScalarLimit)
        return false;
      break;
    case StringIntrinsicKind::IndexOf:
      if (!Small(1) || !Small(3) || !N(4) || *N(4) < 0 || *N(4) > *N(1) ||
          *N(3) == 0 ||
          std::max<int64_t>(0, *N(1) - *N(4) - *N(3) + 1) * *N(3) >
              StringSearchComparisonLimit)
        return false;
      break;
    case StringIntrinsicKind::Compress:
    case StringIntrinsicKind::Inflate:
      if (!Small(4) || (*N(4) > 8 && !PreserveScalarConversions))
        return false;
      break;
    default:
      if (!Small(4))
        return false;
      break;
    }
  }
  CallInst *Call = dyn_cast<CallInst>(&CB);
  if (!Call)
    Call = changeToCall(cast<InvokeInst>(&CB));
  if (Identity) {
    IRBuilder<> B(Call);
    Value *V = Eq ? B.getInt32(1)
                  : B.CreateSub(Call->getArgOperand(1), Call->getArgOperand(3));
    Call->replaceAllUsesWith(V);
    Call->eraseFromParent();
  } else {
    Expansion(*Call, *Op).run();
  }
  return true;
}
} // namespace

namespace {
bool isArrayLengthRead(const CallBase *CB) {
  if (!CB || !pea::isJeandleArrayLength(CB) || CB->hasOperandBundles())
    return false;
  FunctionType *Ty = CB->getFunctionType();
  return !Ty->isVarArg() && Ty->getReturnType()->isIntegerTy(32) &&
         Ty->getNumParams() == 1 && Ty->getParamType(0)->isPointerTy() &&
         Ty->getParamType(0)->getPointerAddressSpace() == 1;
}

// This is a profitability query, not an identity or stable-content proof.
// The existing PEA and VM callback consumers still authorize those folds.
bool hasScalarArrayOpportunity(Value *Array, const LoopInfo &LI,
                               BatchAAResults &AA) {
  SmallVector<const Value *, 8> Pending{Array};
  SmallPtrSet<const Value *, 8> Visited;
  while (!Pending.empty()) {
    const Value *V = Pending.pop_back_val();
    if (!Visited.insert(V).second)
      continue;
    SmallVector<const Value *, 4> Objects;
    getUnderlyingObjects(V, Objects, &LI);
    for (const Value *Object : Objects) {
      if (auto *CB = dyn_cast<CallBase>(Object)) {
        if (pea::isJeandleAllocation(CB))
          return true;
      }
      if (auto *Load = dyn_cast<LoadInst>(Object)) {
        auto *MutableLoad = const_cast<LoadInst *>(Load);
        if (getOopHandleLoadId(MutableLoad))
          return true;
        if (isJavaOopType(Load->getType())) {
          if (Value *Available =
                  FindAvailableLoadedValue(MutableLoad, AA, nullptr)) {
            Pending.push_back(Available);
          } else {
            // PEA may resolve an array-valued field of a local holder to a
            // symbolic array. Preserve that related opportunity, without
            // using the holder as proof of the loaded array's identity.
            Pending.push_back(Load->getPointerOperand());
          }
        }
      }
      if (auto *Freeze = dyn_cast<FreezeInst>(Object))
        Pending.push_back(Freeze->getOperand(0));
    }
  }
  return false;
}
} // namespace

PreservedAnalyses
StringIntrinsicSpecialization::run(Function &F, FunctionAnalysisManager &FAM) {
  if (F.getName().starts_with("jeandle."))
    return PreservedAnalyses::all();
  struct Plan {
    CallBase *Call;
    bool PreserveScalarConversions;
    SmallVector<std::pair<unsigned, ConstantInt *>, 4> Constants;
  };
  SmallVector<Plan, 8> Plans;
  LazyValueInfo *LVI = nullptr;
  const LoopInfo *LI = nullptr;
  DominatorTree *DT = nullptr;
  DenseMap<Value *, SmallVector<CallBase *, 4>> Lengths;
  for (Instruction &I : instructions(F))
    if (auto *CB = dyn_cast<CallBase>(&I))
      if (isArrayLengthRead(CB)) {
        auto &Calls = Lengths[CB->getArgOperand(0)];
        if (Calls.size() < 16)
          Calls.push_back(CB);
      }
  for (Instruction &I : instructions(F)) {
    auto *CB = dyn_cast<CallBase>(&I);
    if (!CB || CB->hasOperandBundles() ||
        (isa<CallInst>(CB) && cast<CallInst>(CB)->isMustTailCall()))
      continue;
    auto Op = decodeStringIntrinsic(*CB);
    if (!Op)
      continue;
    Plan P{CB, false, {}};
    for (unsigned Arg = 0; Arg != CB->arg_size(); ++Arg) {
      Value *V = CB->getArgOperand(Arg);
      if (!V->getType()->isIntegerTy() || isa<Constant>(V))
        continue;
      if (!LVI)
        LVI = &FAM.getResult<LazyValueAnalysis>(F);
      auto *C = dyn_cast_or_null<ConstantInt>(LVI->getConstant(V, CB));
      auto *Length = dyn_cast<CallBase>(V);
      if (!C && isArrayLengthRead(Length)) {
        if (!DT)
          DT = &FAM.getResult<DominatorTreeAnalysis>(F);
        // Repeated length reads can straddle writes or allocation calls.
        // Only the immutable length feeds this String specialization; the
        // calls and every mutable element access retain their semantics.
        for (CallBase *Other : Lengths[Length->getArgOperand(0)])
          if (DT->dominates(Other, CB))
            if ((C = dyn_cast_or_null<ConstantInt>(
                     LVI->getConstant(Other, CB))))
              break;
      }
      if (C)
        P.Constants.emplace_back(Arg, C);
    }
    Value *Count = Op->isConversion() ? CB->getArgOperand(4) : nullptr;
    for (auto [Arg, C] : P.Constants)
      if (Arg == 4)
        Count = C;
    auto *ConstantCount = dyn_cast_or_null<ConstantInt>(Count);
    if ((Op->Kind == StringIntrinsicKind::Compress ||
         Op->Kind == StringIntrinsicKind::Inflate) &&
        ConstantCount && ConstantCount->getSExtValue() > 8 &&
        ConstantCount->getSExtValue() <= StringScalarLimit) {
      if (!LI)
        LI = &FAM.getResult<LoopAnalysis>(F);
      BatchAAResults AA(FAM.getResult<AAManager>(F));
      P.PreserveScalarConversions =
          hasScalarArrayOpportunity(CB->getArgOperand(0), *LI, AA) ||
          hasScalarArrayOpportunity(CB->getArgOperand(2), *LI, AA);
    }
    Plans.push_back(std::move(P));
  }
  // Expansion changes the CFG. Finish every analysis query before applying
  // any plan, so later calls never consult stale LVI or loop information.
  bool Changed = false;
  for (Plan &P : Plans) {
    for (auto [Arg, C] : P.Constants) {
      P.Call->setArgOperand(Arg, C);
      Changed = true;
    }
    Changed |= specialize(*P.Call, P.PreserveScalarConversions);
  }
  return Changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
}
