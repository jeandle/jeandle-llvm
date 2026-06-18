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
#include "llvm/ADT/APFloat.h"
#include "llvm/ADT/APInt.h"
#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/Statistic.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/IR/Jeandle/JeandleUtils.hpp"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Operator.h"
#include "llvm/Support/Debug.h"

#include <climits>
#include <cstring>
#include <optional>

#define DEBUG_TYPE "constant-field-folding"

using namespace llvm;

STATISTIC(NumFieldsFolded, "Number of constant field loads folded");
STATISTIC(NumRounds, "Number of folding rounds");
STATISTIC(NumOopChains, "Number of oop chains followed");

namespace {

using llvm::jeandle::getOopHandleId;
using llvm::jeandle::HotspotBasicType;
using llvm::jeandle::isNarrowOopType;
using llvm::jeandle::isJavaOopType;
using llvm::jeandle::isOopType;
using llvm::jeandle::T_ARRAY;
using llvm::jeandle::T_BOOLEAN;
using llvm::jeandle::T_BYTE;
using llvm::jeandle::T_CHAR;
using llvm::jeandle::T_DOUBLE;
using llvm::jeandle::T_FLOAT;
using llvm::jeandle::T_INT;
using llvm::jeandle::T_LONG;
using llvm::jeandle::T_OBJECT;
using llvm::jeandle::T_SHORT;

// Three-state lattice used by the ConstOop dataflow analysis.
//
//   Top      — we have not seen any source for this value yet; acts as the
//              identity element under meet.
//   Constant — we know the value originates from a specific oop_handle_*
//              global, identified by Id.
//   Bottom   — we have proven the value cannot be tied to a single
//              oop_handle (either two distinct sources flow in, or some
//              opaque producer flows in).
//
// meet: Top ⊓ x = x ; Bottom ⊓ x = Bottom ; C{a} ⊓ C{a} = C{a} ;
//       C{a} ⊓ C{b} = Bottom (when a != b).
struct ConstOopLattice {
  enum class Kind : uint8_t { Top, Constant, Bottom };
  Kind K = Kind::Top;
  int Id = 0;

  static ConstOopLattice top() { return {Kind::Top, 0}; }
  static ConstOopLattice bottom() { return {Kind::Bottom, 0}; }
  static ConstOopLattice constant(int Id) { return {Kind::Constant, Id}; }

  bool isTop() const { return K == Kind::Top; }
  bool isConstant() const { return K == Kind::Constant; }
  bool isBottom() const { return K == Kind::Bottom; }

  ConstOopLattice meet(ConstOopLattice O) const {
    if (K == Kind::Top)
      return O;
    if (O.K == Kind::Top)
      return *this;
    if (K == Kind::Bottom || O.K == Kind::Bottom)
      return bottom();
    return Id == O.Id ? *this : bottom();
  }

  bool operator==(ConstOopLattice O) const {
    return K == O.K && (K != Kind::Constant || Id == O.Id);
  }
  bool operator!=(ConstOopLattice O) const { return !(*this == O); }
};

struct FieldLoadMatch {
  LoadInst *Load;
  GetElementPtrInst *GEP; // null for direct-base loads or constant-expr GEPs.
  int OopId;
  int Offset;
};

bool isDecodeHeapOopCall(User *U) {
  auto *CB = dyn_cast<CallBase>(U);
  if (!CB || !isOopType(CB->getType()))
    return false;

  Function *Callee = CB->getCalledFunction();
  return Callee && Callee->getName() == "jeandle.decode_heap_oop";
}

// If `LI` is a load from an oop_handle_* global, return its id.
std::optional<int> getOopHandleLoadId(LoadInst *LI) {
  if (!LI || !isOopType(LI->getType()))
    return std::nullopt;
  return getOopHandleId(LI->getPointerOperand());
}

// Returns true for instructions that we treat as a one-step pointer
// forwarder in the lattice — i.e. their result's ConstOop lattice value
// is determined by their operands.
//
// Sources (loads from oop_handle_* globals) are handled separately as
// initial seeds and are NOT forwarders.
bool isForwarder(Instruction &I) {
  if (!isOopType(I.getType()))
    return false;
  if (isa<PHINode>(&I) || isa<SelectInst>(&I) || isa<BitCastInst>(&I) ||
      isa<AddrSpaceCastInst>(&I) || isa<FreezeInst>(&I))
    return true;
  if (auto *GEP = dyn_cast<GetElementPtrInst>(&I))
    return GEP->hasAllZeroIndices();
  if (auto *II = dyn_cast<IntrinsicInst>(&I))
    return II->getIntrinsicID() == Intrinsic::launder_invariant_group ||
           II->getIntrinsicID() == Intrinsic::strip_invariant_group;
  return false;
}

// Look up V's lattice value. Any oop-typed value not in `States` is
// implicitly Bottom — it is some opaque producer we cannot trace. Non-oop
// values are also Bottom (they cannot originate a ConstOop).
ConstOopLattice getLattice(Value *V,
                           const DenseMap<Value *, ConstOopLattice> &States) {
  auto It = States.find(V);
  if (It != States.end())
    return It->second;
  return ConstOopLattice::bottom();
}

// Compute the lattice value for a forwarder instruction by taking the meet
// of its operand lattice values.
ConstOopLattice
transferForwarder(Instruction &I,
                  const DenseMap<Value *, ConstOopLattice> &States) {
  if (auto *PN = dyn_cast<PHINode>(&I)) {
    ConstOopLattice Result = ConstOopLattice::top();
    for (Value *Inc : PN->incoming_values()) {
      Result = Result.meet(getLattice(Inc, States));
      if (Result.isBottom())
        return Result;
    }
    return Result;
  }

  if (auto *SI = dyn_cast<SelectInst>(&I))
    return getLattice(SI->getTrueValue(), States)
        .meet(getLattice(SI->getFalseValue(), States));

  if (isa<BitCastInst>(&I) || isa<AddrSpaceCastInst>(&I) || isa<FreezeInst>(&I))
    return getLattice(I.getOperand(0), States);

  if (auto *GEP = dyn_cast<GetElementPtrInst>(&I)) {
    assert(GEP->hasAllZeroIndices() && "non-zero GEP is not a forwarder");
    return getLattice(GEP->getPointerOperand(), States);
  }

  if (auto *II = dyn_cast<IntrinsicInst>(&I)) {
    assert((II->getIntrinsicID() == Intrinsic::launder_invariant_group ||
            II->getIntrinsicID() == Intrinsic::strip_invariant_group) &&
           "unexpected intrinsic in transferForwarder");
    return getLattice(II->getArgOperand(0), States);
  }

  llvm_unreachable("transferForwarder called on non-forwarder");
}

// Compute, for every Value in F that is provably a known ConstOop, its
// oop id. Implementation is a monotonic worklist over the three-state
// ConstOopLattice. Sources (loads from oop_handle_* globals) are seeded
// to Constant{Id}; forwarders (PHI, Select, casts, zero-index GEPs,
// pointer-preserving intrinsics) start at Top and are pulled down to
// Constant or Bottom by repeated meets. Opaque oop-typed producers
// (calls, non-source loads, atomic rmw, ...) are seeded to Bottom AND
// pushed to the worklist, so that Bottom propagates through forwarders
// even when no source feeds them transitively. Convergence is O(N * h)
// where h = 3, regardless of PHI cycles.
DenseMap<Value *, int> computeConstOops(Function &F) {
  DenseMap<Value *, ConstOopLattice> States;
  SmallVector<Value *, 32> Worklist;

  // Seed three categories of oop-typed Instructions:
  //   source     — load from oop_handle_*  → Constant{Id}, pushed
  //   forwarder  — PHI / Select / cast / freeze / zero-GEP / invariant.group
  //                                       → Top, not pushed (driven by users
  //                                          of sources/opaques)
  //   opaque     — any other oop-typed instruction (calls, non-source loads,
  //                atomic ops, etc.)       → Bottom, pushed
  //
  // Non-Instruction oop values (Argument, Constant) remain implicitly Bottom
  // via getLattice's fallback — they have no def site to push from.
  for (BasicBlock &BB : F) {
    for (Instruction &I : BB) {
      if (auto *LI = dyn_cast<LoadInst>(&I)) {
        if (std::optional<int> Id = getOopHandleLoadId(LI)) {
          States[&I] = ConstOopLattice::constant(*Id);
          Worklist.push_back(&I);
          continue;
        }
      }
      if (isForwarder(I)) {
        States[&I] = ConstOopLattice::top();
        continue;
      }
      if (isOopType(I.getType())) {
        States[&I] = ConstOopLattice::bottom();
        Worklist.push_back(&I);
      }
    }
  }

  // Worklist propagation. Whenever a value's lattice state changes, push
  // all forwarder users so they can re-evaluate. Sources never change
  // after seeding.
  while (!Worklist.empty()) {
    Value *V = Worklist.pop_back_val();
    for (User *U : V->users()) {
      auto *I = dyn_cast<Instruction>(U);
      if (!I || !isForwarder(*I))
        continue;
      ConstOopLattice NewState = transferForwarder(*I, States);
      auto It = States.find(I);
      if (It == States.end() || It->second != NewState) {
        States[I] = NewState;
        Worklist.push_back(I);
      }
    }
  }

  DenseMap<Value *, int> Result;
  for (auto &Entry : States) {
    if (Entry.second.isConstant())
      Result[Entry.first] = Entry.second.Id;
  }
  return Result;
}

std::optional<int> lookupConstOop(Value *V,
                                  const DenseMap<Value *, int> &ConstOops) {
  auto It = ConstOops.find(V);
  if (It == ConstOops.end())
    return std::nullopt;
  return It->second;
}

// Match a load whose pointer resolves, through any chain of constant-
// offset GEPs and pointer-preserving casts, to a known ConstOop.
//
// Uses `stripAndAccumulateConstantOffsets`, the canonical LLVM helper.
// It correctly scales by source-element size, handles GEPs with any
// number of constant indices, walks through nested GEPs, and strips
// bitcast / addrspacecast. With AllowInvariantGroup=true it also walks
// through llvm.launder.invariant.group / llvm.strip.invariant.group.
std::optional<FieldLoadMatch>
matchFieldLoad(LoadInst *LI, const DenseMap<Value *, int> &ConstOops,
               const DataLayout &DL) {
  if (!LI)
    return std::nullopt;

  Value *Ptr = LI->getPointerOperand();
  unsigned IdxBits = DL.getIndexTypeSizeInBits(Ptr->getType());
  APInt Offset(IdxBits, 0, /*isSigned=*/true);
  Value *Base = Ptr->stripAndAccumulateConstantOffsets(
      DL, Offset, /*AllowNonInbounds=*/true, /*AllowInvariantGroup=*/true);

  std::optional<int> BaseId = lookupConstOop(Base, ConstOops);
  if (!BaseId)
    return std::nullopt;

  if (!Offset.isSignedIntN(sizeof(int) * CHAR_BIT))
    return std::nullopt;
  int OffsetVal = static_cast<int>(Offset.getSExtValue());

  // For cleanup we only delete the immediate GEP if it is an Instruction
  // GEP that becomes use-empty after the fold; ConstantExpr GEPs and
  // direct loads have no instruction to erase.
  GetElementPtrInst *ImmediateGEP = dyn_cast<GetElementPtrInst>(Ptr);

  return FieldLoadMatch{LI, ImmediateGEP, *BaseId, OffsetVal};
}

bool isSubIntBasicType(int BasicType) {
  return BasicType == T_BOOLEAN || BasicType == T_BYTE || BasicType == T_CHAR ||
         BasicType == T_SHORT;
}

LoadInst *createConstOopLoad(Module &M, IRBuilder<> &Builder, int OopId) {
  LLVMContext &Ctx = M.getContext();
  Type *OopTy = PointerType::get(Ctx, jeandle::AddrSpace::JavaHeapAddrSpace);
  const auto *CB = jeandle::getVMCallbacks();
  assert(CB && CB->GetOopHandleName && "GetOopHandleName callback required");
  const char *Name = CB->GetOopHandleName(OopId);
  GlobalVariable *GV = cast<GlobalVariable>(M.getOrInsertGlobal(Name, OopTy));
  GV->setDSOLocal(true);
  return Builder.CreateLoad(OopTy, GV, "folded.oop");
}

bool replaceSubIntLoad(LoadInst *LI, int BasicType, int Value) {
  if (!isSubIntBasicType(BasicType))
    return false;

  // The load must read exactly one byte for boolean/byte fields and two
  // bytes for char/short fields. Anything else is a layout mismatch and
  // we conservatively refuse to fold — the `Value` returned by the VM is
  // a widened int and would not match the actual memory contents.
  unsigned ExpectedBits =
      (BasicType == T_BOOLEAN || BasicType == T_BYTE) ? 8 : 16;
  auto *IntTy = dyn_cast<IntegerType>(LI->getType());
  if (!IntTy || IntTy->getBitWidth() != ExpectedBits)
    return false;

  // Fast path: if the load has a single CastInst user that matches the
  // field's natural sign-extension (zext for boolean/char, sext for
  // byte/short), fold the (load + cast) pair into a single widened
  // ConstantInt at the cast's type. A non-matching cast falls through
  // to the slow path, which is still correct (the truncated constant
  // produces the same observed bits when subsequently widened).
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

  bool IsSigned = (BasicType == T_BYTE || BasicType == T_SHORT);
  auto *C = ConstantInt::get(IntTy, Value, IsSigned);
  LI->replaceAllUsesWith(C);
  LI->eraseFromParent();
  return true;
}

bool foldFieldLoad(Module &M, const jeandle::VMCallbacks &CB,
                   const FieldLoadMatch &Match) {
  LoadInst *LI = Match.Load;
  int OopId = Match.OopId;
  int Offset = Match.Offset;

  int BasicType = CB.GetConstantFieldInfo(OopId, Offset);
  if (BasicType < 0)
    return false;

  int64_t RawValue = CB.GetConstantFieldValue(OopId, Offset);

  IRBuilder<> Builder(LI);

  switch (BasicType) {
  case T_BOOLEAN:
  case T_BYTE:
  case T_CHAR:
  case T_SHORT:
    return replaceSubIntLoad(LI, BasicType, static_cast<int>(RawValue));

  case T_INT: {
    if (!LI->getType()->isIntegerTy(32))
      return false;
    auto *C = ConstantInt::get(LI->getType(), static_cast<int>(RawValue));
    LI->replaceAllUsesWith(C);
    LI->eraseFromParent();
    return true;
  }

  case T_LONG: {
    if (!LI->getType()->isIntegerTy(64))
      return false;
    auto *C = ConstantInt::get(LI->getType(), RawValue);
    LI->replaceAllUsesWith(C);
    LI->eraseFromParent();
    return true;
  }

  case T_FLOAT: {
    if (!LI->getType()->isFloatTy())
      return false;
    uint32_t RawBits = static_cast<uint32_t>(RawValue);
    auto *C = ConstantFP::get(
        LI->getType(), APFloat(APFloat::IEEEsingle(), APInt(32, RawBits)));
    LI->replaceAllUsesWith(C);
    LI->eraseFromParent();
    return true;
  }

  case T_DOUBLE: {
    if (!LI->getType()->isDoubleTy())
      return false;
    uint64_t RawBits = static_cast<uint64_t>(RawValue);
    auto *C = ConstantFP::get(
        LI->getType(), APFloat(APFloat::IEEEdouble(), APInt(64, RawBits)));
    LI->replaceAllUsesWith(C);
    LI->eraseFromParent();
    return true;
  }

  case T_OBJECT:
  case T_ARRAY: {
    if (!isJavaOopType(LI->getType()))
      return false;
    int NewOopId = static_cast<int>(RawValue);
    if (isOopType(LI->getType())) {
      Value *NewValue = nullptr;
      if (NewOopId < 0) {
        NewValue = ConstantPointerNull::get(cast<PointerType>(LI->getType()));
      } else {
        NewValue = createConstOopLoad(M, Builder, NewOopId);
        ++NumOopChains;
      }
      LI->replaceAllUsesWith(NewValue);
      LI->eraseFromParent();
    } else if (isNarrowOopType(LI->getType())) {
      SmallVector<CallBase *, 4> DecodeUsers;
      for (User *U : LI->users()) {
        if (!isDecodeHeapOopCall(U))
          return false;
        DecodeUsers.push_back(cast<CallBase>(U));
      }
      if (DecodeUsers.empty())
        return false;

      Type *OopTy = PointerType::get(M.getContext(),
                                    jeandle::AddrSpace::JavaHeapAddrSpace);
      Value *NewValue = nullptr;
      if (NewOopId < 0) {
        NewValue = ConstantPointerNull::get(cast<PointerType>(OopTy));
      } else {
        NewValue = createConstOopLoad(M, Builder, NewOopId);
        ++NumOopChains;
      }

      for (CallBase *Decode : DecodeUsers) {
        Decode->replaceAllUsesWith(NewValue);
        Decode->eraseFromParent();
      }
      if (LI->use_empty())
        LI->eraseFromParent();
    }
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
  assert(CB && CB->GetConstantFieldInfo && CB->GetConstantFieldValue &&
         "VMCallbacks must be set");

  const DataLayout &DL = M->getDataLayout();

  constexpr unsigned MaxRounds = 64;
  unsigned Round = 0;
  bool Changed = false;
  bool RoundChanged = false;
  do {
    if (++Round > MaxRounds) {
      LLVM_DEBUG(dbgs() << "CFF: max rounds reached, stopping\n");
      break;
    }
    ++NumRounds;
    RoundChanged = false;
    DenseMap<Value *, int> ConstOops = computeConstOops(F);
    ReversePostOrderTraversal<Function *> RPOT(&F);

    SmallVector<LoadInst *, 16> Loads;
    for (BasicBlock *BB : RPOT) {
      for (Instruction &I : *BB) {
        if (auto *LI = dyn_cast<LoadInst>(&I))
          Loads.push_back(LI);
      }
    }

    for (LoadInst *LI : Loads) {
      std::optional<FieldLoadMatch> Match = matchFieldLoad(LI, ConstOops, DL);
      if (!Match)
        continue;

      LLVM_DEBUG(dbgs() << "CFF: candidate " << *LI << " oop=" << Match->OopId
                        << " offset=" << Match->Offset << "\n");
      if (foldFieldLoad(*M, *CB, *Match)) {
        ++NumFieldsFolded;
        RoundChanged = true;
        Changed = true;
        if (Match->GEP && Match->GEP->use_empty())
          Match->GEP->eraseFromParent();
      }
    }
  } while (RoundChanged);

  if (!Changed)
    return PreservedAnalyses::all();

  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>();
  return PA;
}
