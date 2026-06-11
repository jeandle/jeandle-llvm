//===- ConstantFieldFolding.cpp - Fold constant Java fields ---------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/ConstantFieldFolding.h"
#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Debug.h"

#include <climits>
#include <cstring>
#include <optional>

#define DEBUG_TYPE "constant-field-folding"

using namespace llvm;

namespace {

enum HotSpotBasicType {
  T_BOOLEAN = 4,
  T_CHAR = 5,
  T_FLOAT = 6,
  T_DOUBLE = 7,
  T_BYTE = 8,
  T_SHORT = 9,
  T_INT = 10,
  T_LONG = 11,
  T_OBJECT = 12,
  T_ARRAY = 13,
};

struct ConstOop {
  int Id;

  bool operator==(const ConstOop &Other) const { return Id == Other.Id; }
  bool operator!=(const ConstOop &Other) const { return !(*this == Other); }
};

struct FieldLoadMatch {
  LoadInst *Load;
  int OopId;
  int Offset;
};

bool isJavaOopType(Type *Ty) {
  auto *PT = dyn_cast<PointerType>(Ty);
  return PT && PT->getAddressSpace() == jeandle::AddrSpace::JavaHeapAddrSpace;
}

std::optional<int> parseOopHandleId(StringRef Name) {
  if (!Name.starts_with("oop_handle_"))
    return std::nullopt;

  StringRef Rest = Name.substr(strlen("oop_handle_"));
  size_t Pos = Rest.rfind('_');
  StringRef IdText = Pos == StringRef::npos ? Rest : Rest.substr(Pos + 1);

  int Id = 0;
  if (IdText.empty() || IdText.getAsInteger(10, Id))
    return std::nullopt;
  return Id;
}

std::optional<int> getOopHandleId(Value *V) {
  auto *GV = dyn_cast<GlobalVariable>(V->stripPointerCasts());
  if (!GV)
    return std::nullopt;
  return parseOopHandleId(GV->getName());
}

std::optional<ConstOop>
getMappedConstOop(Value *V, const DenseMap<Value *, ConstOop> &ConstOops) {
  auto It = ConstOops.find(V);
  if (It == ConstOops.end())
    return std::nullopt;
  return It->second;
}

std::optional<ConstOop>
transferConstOop(Instruction &I, const DenseMap<Value *, ConstOop> &ConstOops) {
  if (!isJavaOopType(I.getType()))
    return std::nullopt;

  if (auto *LI = dyn_cast<LoadInst>(&I)) {
    if (std::optional<int> Id = getOopHandleId(LI->getPointerOperand()))
      return ConstOop{*Id};
    return std::nullopt;
  }

  if (auto *BC = dyn_cast<BitCastInst>(&I))
    return getMappedConstOop(BC->getOperand(0), ConstOops);

  if (auto *ASC = dyn_cast<AddrSpaceCastInst>(&I))
    return getMappedConstOop(ASC->getOperand(0), ConstOops);

  if (auto *FI = dyn_cast<FreezeInst>(&I))
    return getMappedConstOop(FI->getOperand(0), ConstOops);

  if (auto *SI = dyn_cast<SelectInst>(&I)) {
    std::optional<ConstOop> TrueOop =
        getMappedConstOop(SI->getTrueValue(), ConstOops);
    std::optional<ConstOop> FalseOop =
        getMappedConstOop(SI->getFalseValue(), ConstOops);
    if (TrueOop && FalseOop && *TrueOop == *FalseOop)
      return TrueOop;
    return std::nullopt;
  }

  if (auto *PN = dyn_cast<PHINode>(&I)) {
    std::optional<ConstOop> Merged;
    bool SawIncoming = false;
    for (Value *Incoming : PN->incoming_values()) {
      if (Incoming == PN)
        continue;
      std::optional<ConstOop> IncomingOop =
          getMappedConstOop(Incoming, ConstOops);
      if (!IncomingOop)
        return std::nullopt;
      if (!Merged) {
        Merged = IncomingOop;
      } else if (*Merged != *IncomingOop) {
        return std::nullopt;
      }
      SawIncoming = true;
    }
    if (SawIncoming)
      return Merged;
  }

  return std::nullopt;
}

DenseMap<Value *, ConstOop> computeConstOops(Function &F) {
  DenseMap<Value *, ConstOop> ConstOops;
  ReversePostOrderTraversal<Function *> RPOT(&F);

  bool Changed = false;
  do {
    Changed = false;
    for (BasicBlock *BB : RPOT) {
      for (Instruction &I : *BB) {
        std::optional<ConstOop> NewState = transferConstOop(I, ConstOops);
        auto It = ConstOops.find(&I);
        if (!NewState) {
          if (It != ConstOops.end()) {
            ConstOops.erase(It);
            Changed = true;
          }
          continue;
        }

        if (It == ConstOops.end()) {
          ConstOops.insert({&I, *NewState});
          Changed = true;
        } else if (It->second != *NewState) {
          It->second = *NewState;
          Changed = true;
        }
      }
    }
  } while (Changed);

  return ConstOops;
}

std::optional<int> getSingleConstantGEPOffset(GetElementPtrInst *GEP) {
  if (!GEP || GEP->getNumIndices() != 1)
    return std::nullopt;

  auto Idx = GEP->idx_begin();
  auto *CI = dyn_cast<ConstantInt>(Idx->get());
  if (!CI)
    return std::nullopt;

  int64_t Offset = CI->getSExtValue();
  if (Offset < INT_MIN || Offset > INT_MAX)
    return std::nullopt;
  return static_cast<int>(Offset);
}

std::optional<FieldLoadMatch>
matchFieldLoad(LoadInst *LI, const DenseMap<Value *, ConstOop> &ConstOops) {
  if (!LI)
    return std::nullopt;

  auto *GEP =
      dyn_cast<GetElementPtrInst>(LI->getPointerOperand()->stripPointerCasts());
  std::optional<int> Offset = getSingleConstantGEPOffset(GEP);
  if (!Offset)
    return std::nullopt;

  std::optional<ConstOop> Base =
      getMappedConstOop(GEP->getPointerOperand(), ConstOops);
  if (!Base)
    return std::nullopt;

  return FieldLoadMatch{LI, Base->Id, *Offset};
}

bool isSubIntBasicType(int BasicType) {
  return BasicType == T_BOOLEAN || BasicType == T_BYTE ||
         BasicType == T_CHAR || BasicType == T_SHORT;
}

std::string oopHandleName(int OopId) {
  return (Twine("oop_handle_") + Twine(OopId)).str();
}

LoadInst *createConstOopLoad(Module &M, IRBuilder<> &Builder, int OopId) {
  LLVMContext &Ctx = M.getContext();
  Type *OopTy = PointerType::get(Ctx, jeandle::AddrSpace::JavaHeapAddrSpace);
  GlobalVariable *GV = M.getOrInsertGlobal(oopHandleName(OopId), OopTy);
  GV->setDSOLocal(true);
  return Builder.CreateLoad(OopTy, GV, "folded.oop");
}

bool replaceSubIntLoad(LoadInst *LI, int BasicType, int Value) {
  if (!isSubIntBasicType(BasicType))
    return false;

  if (LI->hasOneUse()) {
    if (auto *Ext = dyn_cast<CastInst>(*LI->user_begin())) {
      if ((BasicType == T_BOOLEAN || BasicType == T_CHAR)
              ? isa<ZExtInst>(Ext)
              : isa<SExtInst>(Ext)) {
        auto *C = ConstantInt::get(Ext->getType(), Value);
        Ext->replaceAllUsesWith(C);
        Ext->eraseFromParent();
        if (LI->use_empty())
          LI->eraseFromParent();
        return true;
      }
    }
  }

  if (auto *IntTy = dyn_cast<IntegerType>(LI->getType())) {
    auto *C = ConstantInt::get(IntTy, Value, /*isSigned=*/true);
    LI->replaceAllUsesWith(C);
    LI->eraseFromParent();
    return true;
  }

  return false;
}

bool foldFieldLoad(Module &M, const jeandle::VMCallbacks &CB,
                   const FieldLoadMatch &Match) {
  LoadInst *LI = Match.Load;
  int OopId = Match.OopId;
  int Offset = Match.Offset;

  if (!CB.IsConstantField(OopId, Offset))
    return false;

  int BasicType = CB.GetFieldBasicTypeByOop(OopId, Offset);
  IRBuilder<> Builder(LI);

  switch (BasicType) {
  case T_BOOLEAN:
  case T_BYTE:
  case T_CHAR:
  case T_SHORT:
    return replaceSubIntLoad(LI, BasicType,
                             CB.GetConstantFieldInt(OopId, Offset));
  case T_INT: {
    if (!LI->getType()->isIntegerTy(32))
      return false;
    auto *C = ConstantInt::get(LI->getType(),
                              CB.GetConstantFieldInt(OopId, Offset));
    LI->replaceAllUsesWith(C);
    LI->eraseFromParent();
    return true;
  }
  case T_LONG: {
    if (!LI->getType()->isIntegerTy(64))
      return false;
    auto *C = ConstantInt::get(LI->getType(),
                              CB.GetConstantFieldLong(OopId, Offset));
    LI->replaceAllUsesWith(C);
    LI->eraseFromParent();
    return true;
  }
  case T_FLOAT: {
    if (!LI->getType()->isFloatTy())
      return false;
    auto *Bits =
        ConstantInt::get(Type::getInt32Ty(M.getContext()),
                         static_cast<uint32_t>(
                             CB.GetConstantFieldFloatBits(OopId, Offset)));
    auto *C = ConstantExpr::getBitCast(Bits, LI->getType());
    LI->replaceAllUsesWith(C);
    LI->eraseFromParent();
    return true;
  }
  case T_DOUBLE: {
    if (!LI->getType()->isDoubleTy())
      return false;
    auto *Bits =
        ConstantInt::get(Type::getInt64Ty(M.getContext()),
                         static_cast<uint64_t>(
                             CB.GetConstantFieldDoubleBits(OopId, Offset)));
    auto *C = ConstantExpr::getBitCast(Bits, LI->getType());
    LI->replaceAllUsesWith(C);
    LI->eraseFromParent();
    return true;
  }
  case T_OBJECT:
  case T_ARRAY: {
    if (!isJavaOopType(LI->getType()))
      return false;
    int NewOopId = CB.GetConstantFieldOop(OopId, Offset);
    Value *NewValue = nullptr;
    if (NewOopId < 0) {
      NewValue = ConstantPointerNull::get(cast<PointerType>(LI->getType()));
    } else {
      NewValue = createConstOopLoad(M, Builder, NewOopId);
    }
    LI->replaceAllUsesWith(NewValue);
    LI->eraseFromParent();
    return true;
  }
  default:
    return false;
  }
}

} // namespace

PreservedAnalyses ConstantFieldFolding::run(Function &F,
                                            FunctionAnalysisManager &FAM) {
  Module *M = F.getParent();
  if (!M->getNamedMetadata(jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();

  const jeandle::VMCallbacks *CB = jeandle::getVMCallbacks();
  assert(CB && CB->IsConstantField && CB->GetFieldBasicTypeByOop &&
         CB->GetConstantFieldInt && CB->GetConstantFieldLong &&
         CB->GetConstantFieldFloatBits && CB->GetConstantFieldDoubleBits &&
         CB->GetConstantFieldOop && "VMCallbacks must be set");

  bool Changed = false;
  bool RoundChanged = false;
  do {
    RoundChanged = false;
    DenseMap<Value *, ConstOop> ConstOops = computeConstOops(F);
    ReversePostOrderTraversal<Function *> RPOT(&F);

    SmallVector<LoadInst *, 16> Loads;
    for (BasicBlock *BB : RPOT) {
      for (Instruction &I : *BB) {
        if (auto *LI = dyn_cast<LoadInst>(&I))
          Loads.push_back(LI);
      }
    }

    for (LoadInst *LI : Loads) {
      if (LI->getParent() == nullptr)
        continue;
      std::optional<FieldLoadMatch> Match = matchFieldLoad(LI, ConstOops);
      if (!Match)
        continue;

      LLVM_DEBUG(dbgs() << "CFF: candidate " << *LI << " oop=" << Match->OopId
                        << " offset=" << Match->Offset << "\n");
      if (foldFieldLoad(*M, *CB, *Match)) {
        RoundChanged = true;
        Changed = true;
      }
    }
  } while (RoundChanged);

  if (!Changed)
    return PreservedAnalyses::all();

  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>();
  return PA;
}
