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
#include "llvm/Analysis/SimplifyQuery.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/IR/Jeandle/JavaType.h"
#include "llvm/IR/Jeandle/JeandleUtils.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Operator.h"
#include "llvm/Support/Debug.h"
#include "llvm/Transforms/Jeandle/JeandleTransformUtils.h"

#include <climits>
#include <cstring>
#include <optional>

#define DEBUG_TYPE "constant-field-folding"

using namespace llvm;

STATISTIC(NumFieldsFolded, "Number of constant field loads folded");
STATISTIC(NumKlassesFolded, "Number of jeandle.load_klass calls folded");
STATISTIC(NumMirrorKlassesFolded,
          "Number of jeandle.load_mirror_klass calls folded");
STATISTIC(NumGetClassesFolded, "Number of jeandle.get_class calls folded");
STATISTIC(NumKlassLayoutHelpersFolded,
          "Number of jeandle.layout_helper calls folded");
STATISTIC(NumKlassInitializedFolded,
          "Number of jeandle.klass_is_initialized calls folded");
STATISTIC(NumRounds, "Number of folding rounds");
STATISTIC(NumOopChains, "Number of oop chains followed");

namespace {

using llvm::jeandle::getOopHandleId;
using llvm::jeandle::HotspotBasicType;
using llvm::jeandle::isJavaOopType;
using llvm::jeandle::isNarrowOopType;
using llvm::jeandle::isWideOopType;
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

// Returns true for instructions that we treat as a one-step pointer
// forwarder in the lattice — i.e. their result's ConstOop lattice value
// is determined by their operands.
//
// Sources (loads from oop_handle_* globals) are handled separately as
// initial seeds and are NOT forwarders.
bool isForwarder(Instruction &I) {
  if (!isJavaOopType(I.getType()))
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

  // Oop-typed arguments are opaque producers. Do not rely only on
  // getLattice's fallback for them: arguments have users, and pushing them is
  // what forces forwarders such as freeze/cast/select/phi to re-evaluate from
  // Top to Bottom when their source is an argument.
  for (Argument &Arg : F.args()) {
    if (isJavaOopType(Arg.getType())) {
      States[&Arg] = ConstOopLattice::bottom();
      Worklist.push_back(&Arg);
    }
  }

  // Seed three categories of oop-typed Instructions:
  //   source     — load from oop_handle_*  → Constant{Id}, pushed
  //   forwarder  — PHI / Select / cast / freeze / zero-GEP / invariant.group
  //                                       → Top, not pushed (driven by users
  //                                          of sources/opaques)
  //   opaque     — any other oop-typed instruction (calls, non-source loads,
  //                atomic ops, etc.)       → Bottom, pushed
  //
  // Other non-instruction oop values (e.g. Constants) remain implicitly Bottom
  // via getLattice's fallback; unlike Arguments, they do not need a def-site
  // worklist seed for this analysis.
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
      if (isJavaOopType(I.getType())) {
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

Constant *klassPointerConstant(LLVMContext &Ctx, Type *Ty, uintptr_t Klass) {
  if (Klass == 0 || !Ty->isPointerTy())
    return nullptr;
  return ConstantExpr::getIntToPtr(
      ConstantInt::get(Type::getInt64Ty(Ctx), Klass), Ty);
}

bool isLoadKlassCall(CallInst *CI) {
  Function *Callee = CI ? CI->getCalledFunction() : nullptr;
  return Callee && Callee->getName() == "jeandle.load_klass" &&
         CI->arg_size() == 1;
}

bool isLoadMirrorKlassCall(CallInst *CI) {
  Function *Callee = CI ? CI->getCalledFunction() : nullptr;
  return Callee && Callee->getName() == "jeandle.load_mirror_klass" &&
         CI->arg_size() == 1;
}

bool isLayoutHelperCall(CallInst *CI) {
  Function *Callee = CI ? CI->getCalledFunction() : nullptr;
  return Callee && Callee->getName() == "jeandle.layout_helper" &&
         CI->arg_size() == 1;
}

bool isKlassInitializedCall(CallInst *CI) {
  Function *Callee = CI ? CI->getCalledFunction() : nullptr;
  return Callee && Callee->getName() == "jeandle.klass_is_initialized" &&
         CI->arg_size() == 1;
}

bool isGetClassCall(CallInst *CI) {
  Function *Callee = CI ? CI->getCalledFunction() : nullptr;
  return Callee && Callee->getName() == "jeandle.get_class" &&
         CI->arg_size() == 1;
}

bool foldGetClassCall(CallInst *CI, const jeandle::VMCallbacks &CB,
                      const DenseMap<Value *, int> &ConstOops,
                      DominatorTree &DT, const DataLayout &DL) {
  if (!isGetClassCall(CI) || !isJavaOopType(CI->getType()) || !CB.GetJavaMirror)
    return false;

  Value *Receiver = CI->getArgOperand(0);
  int MirrorOopId = -1;
  if (std::optional<int> OopId = lookupConstOop(Receiver, ConstOops)) {
    // Constant oop path: derive the actual dynamic Klass from object identity.
    if (!CB.GetOopKlass)
      return false;
    uintptr_t Klass = CB.GetOopKlass(*OopId);
    if (Klass == 0)
      return false;
    MirrorOopId = CB.GetJavaMirror(Klass);
  } else {
    // Java type path: require exact type and non-null proof to preserve NPE.
    SimplifyQuery SQ(DL, &DT, nullptr, CI);
    if (!isKnownNonZero(Receiver, SQ))
      return false;

    jeandle::JavaType ReceiverType = jeandle::getJavaType(Receiver, &DT, CI);
    if (!ReceiverType.isKnown() || !ReceiverType.Exact)
      return false;
    MirrorOopId = CB.GetJavaMirror(ReceiverType.Klass);
  }
  if (MirrorOopId < 0)
    return false;

  Module *M = CI->getModule();
  if (!M)
    return false;
  IRBuilder<> Builder(CI);
  LoadInst *Mirror = createConstOopLoad(*M, Builder, MirrorOopId);
  CI->replaceAllUsesWith(Mirror);
  CI->eraseFromParent();
  return true;
}

bool foldLoadKlassCall(CallInst *CI, const jeandle::VMCallbacks &CB,
                       const DenseMap<Value *, int> &ConstOops,
                       DominatorTree &DT, const DataLayout &DL) {
  if (!isLoadKlassCall(CI))
    return false;

  Value *Receiver = CI->getArgOperand(0);
  uintptr_t Klass = 0;
  if (std::optional<int> OopId = lookupConstOop(Receiver, ConstOops)) {
    // Constant oop path: derive the object's exact dynamic Klass.
    if (!CB.GetOopKlass)
      return false;
    Klass = CB.GetOopKlass(*OopId);
  } else {
    // Exact Java type path: use the statically known receiver Klass.
    SimplifyQuery SQ(DL, &DT, nullptr, CI);
    if (!isKnownNonZero(Receiver, SQ))
      return false;
    jeandle::JavaType ReceiverType = jeandle::getJavaType(Receiver, &DT, CI);
    if (!ReceiverType.isKnown() || !ReceiverType.Exact)
      return false;
    if (!CB.GetKlassConstant)
      return false;
    Klass = CB.GetKlassConstant(ReceiverType.Klass);
  }
  Constant *KlassConstant =
      klassPointerConstant(CI->getContext(), CI->getType(), Klass);
  if (!KlassConstant)
    return false;

  CI->replaceAllUsesWith(KlassConstant);
  CI->eraseFromParent();
  return true;
}

bool foldLoadMirrorKlassCall(CallInst *CI, const jeandle::VMCallbacks &CB,
                             const DenseMap<Value *, int> &ConstOops) {
  if (!isLoadMirrorKlassCall(CI) || !CI->getType()->isPointerTy() ||
      !CB.GetMirrorKlass)
    return false;

  std::optional<int> OopId = lookupConstOop(CI->getArgOperand(0), ConstOops);
  if (!OopId)
    return false;

  uintptr_t Klass = CB.GetMirrorKlass(*OopId);
  if (Klass == jeandle::MirrorKlassUnavailable)
    return false;

  Constant *KlassConstant;
  if (Klass == 0)
    KlassConstant = ConstantPointerNull::get(cast<PointerType>(CI->getType()));
  else
    KlassConstant =
        klassPointerConstant(CI->getContext(), CI->getType(), Klass);
  if (!KlassConstant)
    return false;

  CI->replaceAllUsesWith(KlassConstant);
  CI->eraseFromParent();
  return true;
}

bool foldLayoutHelperCall(CallInst *CI, const jeandle::VMCallbacks &CB) {
  if (!isLayoutHelperCall(CI) || !CI->getType()->isIntegerTy(32) ||
      !CB.GetKlassLayoutHelper)
    return false;

  uintptr_t Klass = jeandle::extractKlassConstant(CI->getArgOperand(0));
  if (Klass == 0)
    return false;

  int LayoutHelper = CB.GetKlassLayoutHelper(Klass);
  if (LayoutHelper == 0)
    return false;

  CI->replaceAllUsesWith(ConstantInt::get(CI->getType(), LayoutHelper));
  CI->eraseFromParent();
  return true;
}

bool foldKlassInitializedCall(CallInst *CI, const jeandle::VMCallbacks &CB) {
  if (!isKlassInitializedCall(CI) || !CI->getType()->isIntegerTy(1) ||
      !CB.IsKlassInitialized)
    return false;

  uintptr_t Klass = jeandle::extractKlassConstant(CI->getArgOperand(0));
  if (Klass == 0)
    return false;

  // Initialization is monotonic. A class known to be fully initialized at
  // compile time stays initialized, so replacing the query with true is safe.
  // A false result is only a snapshot: the class may initialize before this
  // code executes, so retain the JavaOp and its dynamic load.
  if (!CB.IsKlassInitialized(Klass))
    return false;

  CI->replaceAllUsesWith(ConstantInt::getTrue(CI->getContext()));
  CI->eraseFromParent();
  return true;
}

bool isSubIntBasicType(int BasicType) {
  return BasicType == T_BOOLEAN || BasicType == T_BYTE || BasicType == T_CHAR ||
         BasicType == T_SHORT;
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

  auto [BasicType, RawValue] = CB.GetConstantField(OopId, Offset);
  if (BasicType < 0)
    return false;

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

    // The constant oop id is address-space-agnostic: the lattice has already
    // propagated it across any addrspacecast, so we only need to re-materialise
    // the constant at the type each user expects.
    if (!isNarrowOopType(LI->getType())) {
      // Wide (uncompressed) field load: replace with the wide constant.
      Value *NewValue = nullptr;
      if (NewOopId < 0) {
        NewValue = ConstantPointerNull::get(cast<PointerType>(LI->getType()));
      } else {
        NewValue = createConstOopLoad(M, Builder, NewOopId);
        ++NumOopChains;
      }
      LI->replaceAllUsesWith(NewValue);
      LI->eraseFromParent();
      return true;
    }

    // Narrow (compressed) field load. Its decode-cast users
    // (addrspacecast AS3 -> AS1) are replaced by the *wide* constant directly,
    // which drops the cast. This is essential: LLVM cannot fold an
    // addrspacecast between the narrow and wide address spaces (it is a
    // target-defined encode/decode), so leaving `decode(constant)` in place
    // would stop value-dependent uses from folding -- e.g. a null reference
    // compared against null, or a known oop used as a downstream field base.
    // Any remaining (non-decode) user is rewritten to the *narrow* constant.
    // Relies on CFF running before ExpandNarrowOopCast, which is the pass that
    // would lower a surviving cast into a jeandle.encode/decode_heap_oop call.
    Type *WideTy =
        PointerType::get(M.getContext(), jeandle::AddrSpace::JavaHeapAddrSpace);

    SmallVector<AddrSpaceCastInst *, 4> DecodeCasts;
    for (User *U : LI->users())
      if (auto *Cast = dyn_cast<AddrSpaceCastInst>(U))
        if (isWideOopType(Cast->getType()))
          DecodeCasts.push_back(Cast);

    Value *WideC = nullptr;
    if (!DecodeCasts.empty()) {
      if (NewOopId < 0) {
        WideC = ConstantPointerNull::get(cast<PointerType>(WideTy));
      } else {
        WideC = createConstOopLoad(M, Builder, NewOopId);
        ++NumOopChains;
      }
      for (AddrSpaceCastInst *Cast : DecodeCasts) {
        Cast->replaceAllUsesWith(WideC);
        Cast->eraseFromParent();
      }
    }

    if (!LI->use_empty()) {
      // Remaining users want the narrow value.
      Value *NarrowC;
      if (NewOopId < 0) {
        NarrowC = ConstantPointerNull::get(cast<PointerType>(LI->getType()));
      } else {
        if (!WideC) {
          WideC = createConstOopLoad(M, Builder, NewOopId);
          ++NumOopChains;
        }
        NarrowC = Builder.CreateAddrSpaceCast(WideC, LI->getType(),
                                              "folded.narrow.oop");
      }
      LI->replaceAllUsesWith(NarrowC);
    }
    if (LI->use_empty())
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
  assert(CB && CB->GetConstantField && "VMCallbacks must be set");

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
    DominatorTree &DT = FAM.getResult<DominatorTreeAnalysis>(F);

    SmallVector<CallInst *, 16> LoadKlassCalls;
    SmallVector<CallInst *, 16> LoadMirrorKlassCalls;
    SmallVector<CallInst *, 16> GetClassCalls;
    SmallVector<CallInst *, 16> LayoutHelperCalls;
    SmallVector<CallInst *, 16> KlassInitializedCalls;
    SmallVector<LoadInst *, 16> Loads;
    for (BasicBlock *BB : RPOT) {
      for (Instruction &I : *BB) {
        if (auto *CI = dyn_cast<CallInst>(&I)) {
          if (isLoadKlassCall(CI))
            LoadKlassCalls.push_back(CI);
          if (isLoadMirrorKlassCall(CI))
            LoadMirrorKlassCalls.push_back(CI);
          if (isGetClassCall(CI))
            GetClassCalls.push_back(CI);
          if (isLayoutHelperCall(CI))
            LayoutHelperCalls.push_back(CI);
          if (isKlassInitializedCall(CI))
            KlassInitializedCalls.push_back(CI);
        }
        if (auto *LI = dyn_cast<LoadInst>(&I))
          Loads.push_back(LI);
      }
    }

    // Fold object Klass loads before layout-helper queries so that a complete
    // constant-oop -> Klass* -> layout-helper chain collapses in one round.
    for (CallInst *CI : LoadKlassCalls) {
      if (CI->getParent() == nullptr)
        continue;
      if (foldLoadKlassCall(CI, *CB, ConstOops, DT, DL)) {
        ++NumKlassesFolded;
        RoundChanged = true;
        Changed = true;
      }
    }

    for (CallInst *CI : LoadMirrorKlassCalls) {
      if (CI->getParent() == nullptr)
        continue;
      if (foldLoadMirrorKlassCall(CI, *CB, ConstOops)) {
        ++NumMirrorKlassesFolded;
        RoundChanged = true;
        Changed = true;
      }
    }

    for (CallInst *CI : GetClassCalls) {
      if (CI->getParent() == nullptr)
        continue;
      if (foldGetClassCall(CI, *CB, ConstOops, DT, DL)) {
        ++NumGetClassesFolded;
        RoundChanged = true;
        Changed = true;
      }
    }

    for (CallInst *CI : LayoutHelperCalls) {
      if (CI->getParent() == nullptr)
        continue;
      if (foldLayoutHelperCall(CI, *CB)) {
        ++NumKlassLayoutHelpersFolded;
        RoundChanged = true;
        Changed = true;
      }
    }

    for (CallInst *CI : KlassInitializedCalls) {
      if (CI->getParent() == nullptr)
        continue;
      if (foldKlassInitializedCall(CI, *CB)) {
        ++NumKlassInitializedFolded;
        RoundChanged = true;
        Changed = true;
      }
    }

    for (LoadInst *LI : Loads) {
      if (LI->getParent() == nullptr)
        continue;

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
