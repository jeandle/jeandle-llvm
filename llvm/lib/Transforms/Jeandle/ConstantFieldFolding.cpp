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
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/Statistic.h"
#include "llvm/ADT/StringSwitch.h"
#include "llvm/Analysis/LazyValueInfo.h"
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
#include "llvm/IR/Jeandle/StringIntrinsics.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Jeandle/VMConstants.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Operator.h"
#include "llvm/Support/Debug.h"
#include "llvm/Transforms/Jeandle/JeandleTransformUtils.h"

#include <climits>
#include <cstring>
#include <optional>
#include <utility>

#define DEBUG_TYPE "constant-field-folding"

using namespace llvm;

STATISTIC(NumFieldsFolded, "Number of constant field loads folded");
STATISTIC(NumArrayLengthsFolded, "Number of jeandle.arraylength calls folded");
STATISTIC(NumStringCharsFolded, "Number of StringUTF16.getChar calls folded");
STATISTIC(NumKlassesFolded, "Number of jeandle.load_klass calls folded");
STATISTIC(NumMirrorKlassesFolded,
          "Number of jeandle.load_mirror_klass calls folded");
STATISTIC(NumGetClassesFolded, "Number of jeandle.get_class calls folded");
STATISTIC(NumKlassLayoutHelpersFolded,
          "Number of jeandle.layout_helper calls folded");
STATISTIC(NumKlassInitializedFolded,
          "Number of jeandle.klass_is_initialized calls folded");
STATISTIC(NumKlassFieldsFolded, "Number of immutable Klass field loads folded");
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
template <typename T> struct ConstantLattice {
  enum class Kind : uint8_t { Top, Constant, Bottom };
  Kind K = Kind::Top;
  T Id = 0;

  static ConstantLattice top() { return {Kind::Top, 0}; }
  static ConstantLattice bottom() { return {Kind::Bottom, 0}; }
  static ConstantLattice constant(T Id) { return {Kind::Constant, Id}; }

  bool isTop() const { return K == Kind::Top; }
  bool isConstant() const { return K == Kind::Constant; }
  bool isBottom() const { return K == Kind::Bottom; }

  ConstantLattice meet(ConstantLattice O) const {
    if (K == Kind::Top)
      return O;
    if (O.K == Kind::Top)
      return *this;
    if (K == Kind::Bottom || O.K == Kind::Bottom)
      return bottom();
    return Id == O.Id ? *this : bottom();
  }

  bool operator==(ConstantLattice O) const {
    return K == O.K && (K != Kind::Constant || Id == O.Id);
  }
  bool operator!=(ConstantLattice O) const { return !(*this == O); }
};

using ConstOopLattice = ConstantLattice<int>;
using ClassQueryLattice = ConstantLattice<uintptr_t>;

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
template <typename T>
ConstantLattice<T>
getLattice(Value *V, const DenseMap<Value *, ConstantLattice<T>> &States) {
  auto It = States.find(V);
  if (It != States.end())
    return It->second;
  return ConstantLattice<T>::bottom();
}

// Compute the lattice value for a forwarder instruction by taking the meet
// of its operand lattice values.
template <typename T>
ConstantLattice<T>
transferForwarder(Instruction &I,
                  const DenseMap<Value *, ConstantLattice<T>> &States) {
  if (auto *PN = dyn_cast<PHINode>(&I)) {
    ConstantLattice<T> Result = ConstantLattice<T>::top();
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

  if (auto *FI = dyn_cast<FreezeInst>(&I))
    return jeandle::isProvenDefined(FI->getOperand(0))
               ? getLattice(FI->getOperand(0), States)
               : ConstantLattice<T>::bottom();

  if (isa<BitCastInst>(&I) || isa<AddrSpaceCastInst>(&I))
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

// A PHI/select may merge different constant mirrors even though every path
// gives the same equality result. Ask the VM about object identity rather than
// assuming that distinct oop-handle IDs denote distinct Java objects.
using MirrorPair = std::pair<Value *, Value *>;
using MirrorEqualityResults = DenseMap<MirrorPair, std::optional<int>>;

std::optional<int> classMirrorEquality(Value *Left, Value *Right,
                                       const jeandle::VMCallbacks &CB,
                                       const DenseMap<Value *, int> &ConstOops,
                                       MirrorEqualityResults &Results,
                                       unsigned &Budget, unsigned Depth = 0) {
  if (Budget == 0)
    return std::nullopt;
  --Budget;
  MirrorPair Pair{Left, Right};
  auto It = Results.find(Pair);
  if (It != Results.end())
    return It->second;
  if (Depth >= 32)
    return std::nullopt;

  // Cache unknown results too; the initial entry conservatively breaks cycles.
  Results.try_emplace(Pair, std::nullopt);
  std::optional<int> Result;
  std::optional<int> LeftId = lookupConstOop(Left, ConstOops);
  std::optional<int> RightId = lookupConstOop(Right, ConstOops);
  if (LeftId && RightId) {
    int Same = CB.AreSameClassMirrors(*LeftId, *RightId);
    if (Same >= 0)
      Result = Same;
  } else {
    Value *Merged = LeftId ? Right : Left;
    auto Evaluate = [&](Value *Incoming) {
      return LeftId ? classMirrorEquality(Left, Incoming, CB, ConstOops,
                                          Results, Budget, Depth + 1)
                    : classMirrorEquality(Incoming, Right, CB, ConstOops,
                                          Results, Budget, Depth + 1);
    };
    if (auto *SI = dyn_cast<SelectInst>(Merged)) {
      std::optional<int> True = Evaluate(SI->getTrueValue());
      if (True) {
        std::optional<int> False = Evaluate(SI->getFalseValue());
        if (False && *True == *False)
          Result = *True;
      }
    } else if (auto *PN = dyn_cast<PHINode>(Merged)) {
      for (Value *Incoming : PN->incoming_values()) {
        std::optional<int> Next = Evaluate(Incoming);
        if (!Next || (Result && *Result != *Next)) {
          Result = std::nullopt;
          break;
        }
        Result = *Next;
      }
    }
  }
  Results[Pair] = Result;
  return Result;
}

bool foldClassMirrorComparison(ICmpInst *Cmp, const jeandle::VMCallbacks &CB,
                               const DenseMap<Value *, int> &ConstOops) {
  if (!CB.AreSameClassMirrors || !Cmp->isEquality() ||
      !isJavaOopType(Cmp->getOperand(0)->getType()))
    return false;
  MirrorEqualityResults Results;
  // Count cache hits too, so wide PHIs have bounded traversal cost.
  unsigned Budget = 64;
  std::optional<int> Same = classMirrorEquality(
      Cmp->getOperand(0), Cmp->getOperand(1), CB, ConstOops, Results, Budget);
  if (!Same)
    return false;
  bool Result = Cmp->getPredicate() == CmpInst::ICMP_EQ ? *Same : !*Same;
  Cmp->replaceAllUsesWith(ConstantInt::get(Cmp->getType(), Result));
  Cmp->eraseFromParent();
  return true;
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

bool foldStringGetCharCall(CallInst *CI, const jeandle::VMCallbacks &CB,
                           const DenseMap<Value *, int> &ConstOops,
                           const jeandle::VMConstants &VMConsts,
                           LazyValueInfo &LVI) {
  std::optional<int> OopId = lookupConstOop(CI->getArgOperand(0), ConstOops);
  if (!OopId)
    return false;
  auto *Index = dyn_cast<ConstantInt>(CI->getArgOperand(1));
  if (!Index)
    Index = dyn_cast_or_null<ConstantInt>(
        LVI.getConstant(CI->getArgOperand(1), CI));
  int64_t Base = VMConsts.arrayBaseOffsetFor(jeandle::JBasicType::Byte);
  if (!Index || Index->isNegative() || Base < 0 || Base >= INT_MAX ||
      Index->getSExtValue() > (INT_MAX - Base - 1) / 2)
    return false;
  int Offset = Base + Index->getSExtValue() * 2;
  // Both byte cells must be independently authorized. Unresolved characters
  // retain the JavaOp and eventually lower to one atomic word read.
  auto [FirstType, First] = CB.GetConstantField(*OopId, Offset);
  if (FirstType != T_BYTE)
    return false;
  auto [SecondType, Second] = CB.GetConstantField(*OopId, Offset + 1);
  if (SecondType != T_BYTE)
    return false;
  uint16_t A = static_cast<uint8_t>(First);
  uint16_t B = static_cast<uint8_t>(Second);
  uint16_t Character = CI->getModule()->getDataLayout().isLittleEndian()
                           ? A | (B << 8)
                           : (A << 8) | B;
  LLVM_DEBUG(dbgs() << "CFF: StringUTF16.getChar in "
                    << CI->getFunction()->getName() << " oop=" << *OopId
                    << " offset=" << Offset << " value=" << Character << "\n");
  CI->replaceAllUsesWith(ConstantInt::get(CI->getType(), Character));
  CI->eraseFromParent();
  return true;
}

bool isArrayLengthCall(CallInst *CI) {
  Function *Callee = CI ? CI->getCalledFunction() : nullptr;
  return Callee && Callee->getName() == "jeandle.arraylength" &&
         CI->getFunctionType() == Callee->getFunctionType() &&
         !CI->getFunctionType()->isVarArg() && CI->arg_size() == 1 &&
         CI->getType()->isIntegerTy(32) &&
         isWideOopType(CI->getArgOperand(0)->getType()) &&
         !CI->hasOperandBundles() && !CI->isMustTailCall();
}

bool foldArrayLengthCall(CallInst *CI, const jeandle::VMCallbacks &CB,
                         const DenseMap<Value *, int> &ConstOops,
                         const jeandle::VMConstants &VMConsts) {
  std::optional<int> OopId = lookupConstOop(CI->getArgOperand(0), ConstOops);
  int64_t Offset = VMConsts.arrayLengthOffset();
  if (!OopId || Offset < 0 || Offset > INT_MAX)
    return false;

  auto [BasicType, RawValue] = CB.GetConstantField(*OopId, Offset);
  if (BasicType != T_INT || RawValue < 0 || RawValue > INT_MAX)
    return false;

  CI->replaceAllUsesWith(ConstantInt::get(CI->getType(), RawValue));
  CI->eraseFromParent();
  return true;
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

enum class ClassQueryKind {
  IsArray,
  IsInterface,
  IsPrimitive,
  IsHidden,
  GetModifiers,
  GetAccessFlags,
  GetSuperclass
};

std::optional<ClassQueryKind> classQueryKind(CallInst *CI) {
  Function *Callee = CI->getCalledFunction();
  if (!Callee || CI->getFunctionType() != Callee->getFunctionType() ||
      CI->getCallingConv() != Callee->getCallingConv() ||
      CI->getFunctionType()->isVarArg() || CI->hasOperandBundles() ||
      CI->isMustTailCall() || CI->arg_size() != 1 ||
      !isWideOopType(CI->getArgOperand(0)->getType()))
    return std::nullopt;
  if (Callee->getName() == "jeandle.class_get_superclass")
    return isWideOopType(CI->getType())
               ? std::optional<ClassQueryKind>(ClassQueryKind::GetSuperclass)
               : std::nullopt;
  if (!CI->getType()->isIntegerTy(32))
    return std::nullopt;
  return StringSwitch<std::optional<ClassQueryKind>>(Callee->getName())
      .Case("jeandle.class_is_array", ClassQueryKind::IsArray)
      .Case("jeandle.class_is_interface", ClassQueryKind::IsInterface)
      .Case("jeandle.class_is_primitive", ClassQueryKind::IsPrimitive)
      .Case("jeandle.class_is_hidden", ClassQueryKind::IsHidden)
      .Case("jeandle.class_get_modifiers", ClassQueryKind::GetModifiers)
      .Case("jeandle.class_get_access_flags", ClassQueryKind::GetAccessFlags)
      .Default(std::nullopt);
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
         CI->getFunctionType() == Callee->getFunctionType() &&
         CI->getCallingConv() == Callee->getCallingConv() &&
         !Callee->isVarArg() && CI->arg_size() == 1 &&
         isWideOopType(CI->getType()) &&
         isWideOopType(CI->getArgOperand(0)->getType()) &&
         !CI->hasOperandBundles() && !CI->isMustTailCall();
}

bool isKnownNonNullAt(Value *Receiver, Instruction *Query, DominatorTree &DT,
                      const DataLayout &DL, LazyValueInfo &LVI) {
  SimplifyQuery SQ(DL, &DT, nullptr, Query);
  if (isKnownNonZero(Receiver, SQ))
    return true;

  // ValueTracking bounds its search through uses for a dominating null check.
  // Query the existing block facts as well, so later frame-state uses cannot
  // hide the non-null edge that reaches this operation.
  auto *PtrTy = dyn_cast<PointerType>(Receiver->getType());
  if (!PtrTy)
    return false;
  auto *NonNull = dyn_cast_or_null<ConstantInt>(LVI.getPredicateAt(
      CmpInst::ICMP_NE, Receiver, ConstantPointerNull::get(PtrTy), Query,
      /*UseBlockValue=*/true));
  return NonNull && NonNull->isOne();
}

bool foldGetClassCall(CallInst *CI, const jeandle::VMCallbacks &CB,
                      const DenseMap<Value *, int> &ConstOops,
                      DominatorTree &DT, const DataLayout &DL,
                      jeandle::IsNullEdgeOracle IsNullEdge,
                      LazyValueInfo &LVI) {
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
    if (!isKnownNonNullAt(Receiver, CI, DT, DL, LVI))
      return false;

    jeandle::JavaType ReceiverType =
        jeandle::getJavaType(Receiver, &DT, CI, IsNullEdge);
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
                       DominatorTree &DT, const DataLayout &DL,
                       jeandle::IsNullEdgeOracle IsNullEdge,
                       DenseSet<uintptr_t> &KnownKlasses, LazyValueInfo &LVI) {
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
    if (!isKnownNonNullAt(Receiver, CI, DT, DL, LVI))
      return false;
    jeandle::JavaType ReceiverType =
        jeandle::getJavaType(Receiver, &DT, CI, IsNullEdge);
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

  // A failed lookup must not seed the provenance set: address zero is never
  // a Klass. klassPointerConstant already rejects it; the explicit guard
  // keeps the set's invariant independent of that helper's contract.
  if (Klass != 0)
    KnownKlasses.insert(Klass);
  CI->replaceAllUsesWith(KlassConstant);
  CI->eraseFromParent();
  return true;
}

bool foldLoadMirrorKlassCall(CallInst *CI, const jeandle::VMCallbacks &CB,
                             const DenseMap<Value *, int> &ConstOops,
                             DenseSet<uintptr_t> &KnownKlasses) {
  if (!isLoadMirrorKlassCall(CI) || !CI->getType()->isPointerTy())
    return false;

  auto *Origin = dyn_cast<CallInst>(CI->getArgOperand(0));
  Function *LoadKlass = CI->getModule()->getFunction("jeandle.load_klass");
  Function *Callee = CI->getCalledFunction();
  if (Origin && isGetClassCall(Origin) && LoadKlass &&
      CI->getFunctionType() == Callee->getFunctionType() &&
      CI->getCallingConv() == Callee->getCallingConv() && !Callee->isVarArg() &&
      !CI->hasOperandBundles() && !CI->isMustTailCall() &&
      LoadKlass->arg_size() == 1 && !LoadKlass->isVarArg() &&
      LoadKlass->getReturnType() == CI->getType() &&
      LoadKlass->getFunctionType()->getParamType(0) ==
          Origin->getArgOperand(0)->getType() &&
      LoadKlass->getCallingConv() == CI->getCallingConv()) {
    IRBuilder<> Builder(CI);
    CallInst *Klass = Builder.CreateCall(LoadKlass, {Origin->getArgOperand(0)});
    Klass->setCallingConv(LoadKlass->getCallingConv());
    Klass->setDebugLoc(CI->getDebugLoc());
    CI->replaceAllUsesWith(Klass);
    CI->eraseFromParent();
    return true;
  }
  if (!CB.GetMirrorKlass)
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

  if (auto *LI = dyn_cast<LoadInst>(CI->getArgOperand(0)))
    if (isWideOopType(LI->getType()) && getOopHandleLoadId(LI))
      LI->setMetadata(LLVMContext::MD_nonnull,
                      MDNode::get(CI->getContext(), {}));

  if (Klass != 0)
    KnownKlasses.insert(Klass);
  CI->replaceAllUsesWith(KlassConstant);
  CI->eraseFromParent();
  return true;
}

// Preserve the canonical dynamic check. Only expose a preloaded offset once
// propagation has proved the target Klass constant.
bool specializeConstantClassCheck(CallInst *CI,
                                  const jeandle::VMCallbacks &CB) {
  Function *Callee = CI->getCalledFunction();
  bool Subtype = Callee && Callee->getName() == "jeandle.check_klass_subtype";
  if (!Callee ||
      (!Subtype && Callee->getName() != "jeandle.check_instanceof") ||
      CI->getFunctionType() != Callee->getFunctionType() ||
      CI->getCallingConv() != Callee->getCallingConv() ||
      CI->getFunctionType()->isVarArg() || CI->hasOperandBundles() ||
      CI->isMustTailCall() || !CB.GetSuperCheckOffset || CI->arg_size() != 2 ||
      CI->getArgOperand(0)->getType() !=
          PointerType::get(CI->getContext(), 0) ||
      !CI->getType()->isIntegerTy(1))
    return false;
  unsigned TargetIndex = Subtype ? 1 : 0;
  uintptr_t Klass =
      jeandle::extractKlassConstant(CI->getArgOperand(TargetIndex));
  Function *WithOffset = CI->getModule()->getFunction(
      Subtype ? "jeandle.check_klass_subtype_with_offset"
              : "jeandle.checkcast_nonnull_with_offset");
  if (!Klass || Klass == jeandle::MirrorKlassUnavailable || !WithOffset ||
      WithOffset->getCallingConv() != CI->getCallingConv() ||
      WithOffset->isVarArg() || WithOffset->arg_size() != 3 ||
      WithOffset->getReturnType() != CI->getType() ||
      CI->getArgOperand(1)->getType() !=
          PointerType::get(CI->getContext(), Subtype ? 0 : 1) ||
      WithOffset->getFunctionType()->getParamType(0) !=
          CI->getArgOperand(0)->getType() ||
      WithOffset->getFunctionType()->getParamType(1) !=
          CI->getArgOperand(1)->getType() ||
      !WithOffset->getFunctionType()->getParamType(2)->isIntegerTy(32))
    return false;
  // Only specialize primary-super checks, where the constant offset also
  // removes the secondary-super branch. Preserve the canonical secondary path.
  GlobalVariable *SecondaryOffset = CI->getModule()->getGlobalVariable(
      "Klass.secondary_super_cache_offset", true);
  auto *Secondary =
      SecondaryOffset && SecondaryOffset->isConstant() &&
              SecondaryOffset->hasInitializer()
          ? dyn_cast<ConstantInt>(SecondaryOffset->getInitializer())
          : nullptr;
  int Offset = CB.GetSuperCheckOffset(Klass);
  if (Offset < 0 || !Secondary || !Secondary->getType()->isIntegerTy(32) ||
      Secondary->getValue().getLimitedValue() == static_cast<uint32_t>(Offset))
    return false;
  IRBuilder<> Builder(CI);
  SmallVector<OperandBundleDef, 1> Bundles;
  CI->getOperandBundlesAsDefs(Bundles);
  CallInst *Check = Builder.CreateCall(
      WithOffset,
      {CI->getArgOperand(0), CI->getArgOperand(1), Builder.getInt32(Offset)},
      Bundles);
  Check->setCallingConv(CI->getCallingConv());
  Check->setAttributes(CI->getAttributes());
  Check->copyMetadata(*CI);
  Check->setDebugLoc(CI->getDebugLoc());
  CI->replaceAllUsesWith(Check);
  CI->eraseFromParent();
  return true;
}

std::optional<uintptr_t>
classQueryForConstantMirror(int OopId, ClassQueryKind Kind,
                            const jeandle::VMCallbacks &CB,
                            const jeandle::VMConstants &VMC) {
  if (Kind == ClassQueryKind::GetSuperclass) {
    if (!CB.GetClassSuperclass)
      return std::nullopt;
    uintptr_t Super = CB.GetClassSuperclass(OopId);
    return Super == jeandle::MirrorKlassUnavailable
               ? std::nullopt
               : std::optional<uintptr_t>(Super);
  }
  uintptr_t Klass = CB.GetMirrorKlass(OopId);
  if (Klass == jeandle::MirrorKlassUnavailable)
    return std::nullopt;
  if (!Klass) {
    if (Kind == ClassQueryKind::IsPrimitive)
      return 1;
    if (Kind == ClassQueryKind::GetModifiers ||
        Kind == ClassQueryKind::GetAccessFlags)
      return VMC.jvmAccPublic() | VMC.jvmAccFinal() | VMC.jvmAccAbstract();
    return 0;
  }
  switch (Kind) {
  case ClassQueryKind::IsArray: {
    if (!CB.GetKlassLayoutHelper)
      return std::nullopt;
    int Layout = CB.GetKlassLayoutHelper(Klass);
    return Layout ? std::optional<int>(Layout < 0) : std::nullopt;
  }
  case ClassQueryKind::IsPrimitive:
    return 0;
  case ClassQueryKind::GetModifiers: {
    if (!CB.GetKlassModifierFlags)
      return std::nullopt;
    int Modifiers = CB.GetKlassModifierFlags(Klass);
    return Modifiers >= 0 ? std::optional<int>(Modifiers) : std::nullopt;
  }
  case ClassQueryKind::IsInterface:
  case ClassQueryKind::IsHidden:
  case ClassQueryKind::GetAccessFlags: {
    if (!CB.GetKlassAccessFlags)
      return std::nullopt;
    uint32_t Mask = Kind == ClassQueryKind::IsInterface ? VMC.jvmAccInterface()
                    : Kind == ClassQueryKind::IsHidden
                        ? VMC.jvmAccIsHiddenClass()
                        : VMC.jvmAccWrittenFlags();
    if (Mask & ~jeandle::ClassQueryAccessFlagsMask)
      return std::nullopt;
    int64_t Flags = CB.GetKlassAccessFlags(Klass, Mask);
    if (Flags < 0 || Flags > UINT32_MAX)
      return std::nullopt;
    Flags &= Mask;
    return Kind == ClassQueryKind::GetAccessFlags ? Flags : Flags != 0;
  }
  case ClassQueryKind::GetSuperclass:
    llvm_unreachable("superclass handled before the Klass query");
  }
  llvm_unreachable("unknown Class query kind");
}

// Query properties independently of mirror identity. Forwarders start at Top;
// constant or opaque sources drive a monotonic worklist to a fixed point even
// through cyclic PHIs. A source-free cycle remains Top and cannot be folded.
std::optional<uintptr_t> classQueryForMirror(
    Value *Mirror, ClassQueryKind Kind, const jeandle::VMCallbacks &CB,
    const jeandle::VMConstants &VMC, const DenseMap<Value *, int> &ConstOops,
    SmallVectorImpl<LoadInst *> &NonNullMirrors) {
  DenseMap<Value *, ClassQueryLattice> States;
  DenseMap<Value *, SmallVector<Instruction *, 2>> Users;
  unsigned RemainingVisits = 256;
  auto Visit = [&](auto &&Self, Value *V, unsigned Depth) -> bool {
    if (RemainingVisits == 0)
      return false;
    --RemainingVisits;
    if (States.contains(V))
      return true;
    if (Depth >= 32)
      return false;
    States[V] = ClassQueryLattice::top();
    if (auto *Origin = dyn_cast<CallInst>(V);
        Origin && isGetClassCall(Origin) &&
        (Kind == ClassQueryKind::IsPrimitive ||
         Kind == ClassQueryKind::IsInterface)) {
      States[V] = ClassQueryLattice::constant(0);
      return true;
    }
    if (std::optional<int> OopId = lookupConstOop(V, ConstOops)) {
      auto Result = classQueryForConstantMirror(*OopId, Kind, CB, VMC);
      States[V] = Result ? ClassQueryLattice::constant(*Result)
                         : ClassQueryLattice::bottom();
      if (Result)
        if (auto *LI = dyn_cast<LoadInst>(V))
          if (isWideOopType(LI->getType()) && getOopHandleLoadId(LI))
            NonNullMirrors.push_back(LI);
      return true;
    }
    auto *I = dyn_cast<Instruction>(V);
    if (!I || !isForwarder(*I) ||
        (isa<FreezeInst>(I) && !jeandle::isProvenDefined(I->getOperand(0)))) {
      States[V] = ClassQueryLattice::bottom();
      return true;
    }
    SmallVector<Value *, 4> Inputs;
    if (auto *PN = dyn_cast<PHINode>(I)) {
      // Every incoming edge needs a visit; avoid copying an over-budget PHI.
      if (PN->getNumIncomingValues() > RemainingVisits)
        return false;
      Inputs.append(PN->incoming_values().begin(), PN->incoming_values().end());
    } else if (auto *SI = dyn_cast<SelectInst>(I))
      Inputs = {SI->getTrueValue(), SI->getFalseValue()};
    else
      Inputs.push_back(I->getOperand(0));
    for (Value *Input : Inputs) {
      if (!Self(Self, Input, Depth + 1))
        return false;
      Users[Input].push_back(I);
    }
    return true;
  };
  if (!Visit(Visit, Mirror, 0))
    return std::nullopt;

  SmallVector<Value *, 32> Worklist;
  for (auto &[V, State] : States)
    Worklist.push_back(V);
  while (!Worklist.empty()) {
    Value *V = Worklist.pop_back_val();
    for (Instruction *User : Users[V]) {
      ClassQueryLattice Next =
          States[User].meet(transferForwarder(*User, States));
      if (Next != States[User]) {
        States[User] = Next;
        Worklist.push_back(User);
      }
    }
  }
  ClassQueryLattice Result = States[Mirror];
  return Result.isConstant() ? std::optional<uintptr_t>(Result.Id)
                             : std::nullopt;
}

bool foldClassQueryCall(CallInst *CI, ClassQueryKind Kind,
                        const jeandle::VMCallbacks &CB,
                        const jeandle::VMConstants &VMC,
                        const DenseMap<Value *, int> &ConstOops) {
  if (!CB.GetMirrorKlass)
    return false;
  SmallVector<LoadInst *, 4> NonNullMirrors;
  auto Result = classQueryForMirror(CI->getArgOperand(0), Kind, CB, VMC,
                                    ConstOops, NonNullMirrors);
  if (!Result)
    return false;

  Value *Replacement = nullptr;
  if (Kind == ClassQueryKind::GetSuperclass) {
    if (*Result == 0) {
      Replacement = ConstantPointerNull::get(cast<PointerType>(CI->getType()));
    } else {
      if (!CB.GetJavaMirror)
        return false;
      int OopId = CB.GetJavaMirror(*Result);
      if (OopId < 0)
        return false;
      IRBuilder<> Builder(CI);
      Replacement = createConstOopLoad(*CI->getModule(), Builder, OopId);
    }
  } else {
    Replacement = ConstantInt::get(CI->getType(), *Result);
  }
  // A successful VM query establishes that these handles contain Class
  // mirrors. Expose that fact so a folded query does not leave a null check
  // on the original mirror merge behind.
  for (LoadInst *LI : NonNullMirrors)
    LI->setMetadata(LLVMContext::MD_nonnull, MDNode::get(CI->getContext(), {}));
  CI->replaceAllUsesWith(Replacement);
  CI->eraseFromParent();
  return true;
}

enum class KlassQueryKind { Modifiers, AccessFlags, Super, Mirror };

std::optional<KlassQueryKind> getKlassQueryKind(CallInst *CI) {
  Function *Callee = CI->getCalledFunction();
  if (!Callee || CI->getFunctionType() != Callee->getFunctionType() ||
      CI->getCallingConv() != Callee->getCallingConv() ||
      CI->getFunctionType()->isVarArg() || CI->hasOperandBundles() ||
      CI->isMustTailCall())
    return std::nullopt;

  StringRef Name = Callee->getName();
  KlassQueryKind Kind;
  if (Name == "jeandle.klass_modifiers")
    Kind = KlassQueryKind::Modifiers;
  else if (Name == "jeandle.klass_access_flags")
    Kind = KlassQueryKind::AccessFlags;
  else if (Name == "jeandle.klass_super")
    Kind = KlassQueryKind::Super;
  else if (Name == "jeandle.klass_mirror")
    Kind = KlassQueryKind::Mirror;
  else
    return std::nullopt;

  unsigned NumArgs = Kind == KlassQueryKind::AccessFlags ? 2 : 1;
  Type *KlassTy = PointerType::get(CI->getContext(), 0);
  if (CI->arg_size() != NumArgs || CI->getArgOperand(0)->getType() != KlassTy)
    return std::nullopt;

  switch (Kind) {
  case KlassQueryKind::AccessFlags:
    if (!CI->getArgOperand(1)->getType()->isIntegerTy(32))
      return std::nullopt;
    [[fallthrough]];
  case KlassQueryKind::Modifiers:
    if (!CI->getType()->isIntegerTy(32))
      return std::nullopt;
    break;
  case KlassQueryKind::Super:
    if (CI->getType() != KlassTy)
      return std::nullopt;
    break;
  case KlassQueryKind::Mirror:
    if (!isWideOopType(CI->getType()))
      return std::nullopt;
    break;
  }
  return Kind;
}

bool foldKlassQueryCall(CallInst *CI, KlassQueryKind Kind,
                        const jeandle::VMCallbacks &CB, LazyValueInfo &LVI,
                        DenseSet<uintptr_t> &KnownKlasses) {
  Value *KlassValue = CI->getArgOperand(0);
  uintptr_t Klass = jeandle::extractKlassConstant(KlassValue);
  if (!Klass)
    if (Constant *C = LVI.getConstant(KlassValue, CI))
      Klass = jeandle::extractKlassConstant(C);
  if (!Klass || Klass == jeandle::MirrorKlassUnavailable)
    return false;

  Value *Replacement = nullptr;
  switch (Kind) {
  case KlassQueryKind::Modifiers: {
    if (!CB.GetKlassModifierFlags)
      return false;
    int Modifiers = CB.GetKlassModifierFlags(Klass);
    if (Modifiers < 0)
      return false;
    Replacement = ConstantInt::get(CI->getType(), Modifiers);
    break;
  }
  case KlassQueryKind::AccessFlags: {
    if (!CB.GetKlassAccessFlags)
      return false;
    auto *MaskValue = dyn_cast<ConstantInt>(CI->getArgOperand(1));
    if (!MaskValue)
      MaskValue = dyn_cast_or_null<ConstantInt>(
          LVI.getConstant(CI->getArgOperand(1), CI));
    if (!MaskValue)
      return false;
    uint32_t Mask = MaskValue->getZExtValue();
    // Other access bits are transient VM state, not stable class properties.
    if (Mask & ~jeandle::ClassQueryAccessFlagsMask)
      return false;
    int64_t Flags = CB.GetKlassAccessFlags(Klass, Mask);
    if (Flags < 0 || Flags > UINT32_MAX)
      return false;
    Replacement = ConstantInt::get(CI->getType(), Flags & Mask);
    break;
  }
  case KlassQueryKind::Super: {
    if (!CB.GetSuperKlass)
      return false;
    uintptr_t Super = CB.GetSuperKlass(Klass);
    if (Super == jeandle::MirrorKlassUnavailable)
      return false;
    if (Super)
      KnownKlasses.insert(Super);
    Replacement =
        Super ? klassPointerConstant(CI->getContext(), CI->getType(), Super)
              : ConstantPointerNull::get(cast<PointerType>(CI->getType()));
    break;
  }
  case KlassQueryKind::Mirror: {
    if (!CB.GetJavaMirror || !CB.GetOopHandleName)
      return false;
    int MirrorId = CB.GetJavaMirror(Klass);
    if (MirrorId < 0)
      return false;
    IRBuilder<> Builder(CI);
    Replacement = createConstOopLoad(*CI->getModule(), Builder, MirrorId);
    break;
  }
  }

  CI->replaceAllUsesWith(Replacement);
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

// Only semantic Klass operands establish provenance. A native inttoptr by
// itself might name a Method, a runtime entry or arbitrary C memory.
void collectKnownKlasses(CallBase &Call, DenseSet<uintptr_t> &KnownKlasses) {
  Function *Callee = Call.getCalledFunction();
  if (!Callee || Call.arg_empty())
    return;
  StringRef Name = Callee->getName();
  if (Name != "jeandle.new_instance" && Name != "jeandle.new_array" &&
      Name != "jeandle.layout_helper" &&
      Name != "jeandle.klass_is_initialized" &&
      Name != "jeandle.load_array_element_klass" &&
      Name != "jeandle.check_exact_klass" && Name != "jeandle.checkcast" &&
      Name != "jeandle.check_instanceof")
    return;
  if (uintptr_t Klass = jeandle::extractKlassConstant(Call.getArgOperand(0)))
    KnownKlasses.insert(Klass);
}

bool foldKlassFieldLoad(LoadInst *LI, const jeandle::VMCallbacks &CB,
                        const DenseSet<uintptr_t> &KnownKlasses,
                        const DataLayout &DL) {
  if (!CB.GetKlassConstantField || !LI->isUnordered() || LI->isVolatile() ||
      LI->getPointerAddressSpace() != jeandle::CHeapAddrSpace)
    return false;

  Type *Ty = LI->getType();
  bool IsInt = Ty->isIntegerTy(32);
  bool IsAddress = Ty->isPointerTy() &&
                   Ty->getPointerAddressSpace() == jeandle::CHeapAddrSpace;
  if (!IsInt && !IsAddress)
    return false;

  Value *Ptr = LI->getPointerOperand();
  APInt Offset(DL.getIndexTypeSizeInBits(Ptr->getType()), 0);
  Value *Base = Ptr->stripAndAccumulateConstantOffsets(
      DL, Offset, /*AllowNonInbounds=*/true);
  uintptr_t Klass = jeandle::extractKlassConstant(Base);
  if (!KnownKlasses.contains(Klass) || !Offset.isSignedIntN(32))
    return false;

  unsigned BitWidth = IsInt ? 32 : DL.getPointerTypeSizeInBits(Ty);
  auto [BasicType, RawValue] = CB.GetKlassConstantField(
      Klass, static_cast<int>(Offset.getSExtValue()), BitWidth);
  Constant *Replacement = nullptr;
  if (IsInt && BasicType == jeandle::T_INT)
    Replacement = ConstantInt::get(Ty, RawValue);
  else if (IsAddress && BasicType == jeandle::T_ADDRESS)
    Replacement = ConstantExpr::getIntToPtr(
        ConstantInt::get(DL.getIntPtrType(Ty), RawValue), Ty);
  if (!Replacement)
    return false;

  auto *GEP = dyn_cast<GetElementPtrInst>(Ptr);
  LI->replaceAllUsesWith(Replacement);
  LI->eraseFromParent();
  if (GEP && GEP->use_empty())
    GEP->eraseFromParent();
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

  // The runtime-defined flag globals keep a constant initializer for the
  // whole compilation, so read them back once instead of per folding round.

  const DataLayout &DL = M->getDataLayout();
  const jeandle::VMConstants VMConsts = jeandle::VMConstants::fromModule(*M);

  constexpr unsigned MaxRounds = 64;
  unsigned Round = 0;
  bool Changed = false;
  bool RoundChanged = false;
  DenseSet<uintptr_t> KnownKlasses;
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
    // getResult returns the same cached LVI across rounds within this run;
    // that is safe because CFF only erases non-terminator instructions and
    // never splits blocks (LVI's ValueHandles purge erased values, block
    // state stays valid). Freshness across runs comes from RepeatedConstant
    // Folding's cleanup passes invalidating LVI between wrapper iterations.
    // Any fold that touches terminators or blocks would need to drop the
    // oracle first.
    LazyValueInfo &LVI = FAM.getResult<LazyValueAnalysis>(F);
    LVINullEdgeOracle IsNullEdge{LVI};

    SmallVector<CallInst *, 16> ArrayLengthCalls;
    SmallVector<CallInst *, 16> StringGetCharCalls;
    SmallVector<CallInst *, 16> LoadKlassCalls;
    SmallVector<CallInst *, 16> ClassInstanceChecks;
    SmallVector<CallInst *, 16> LoadMirrorKlassCalls;
    SmallVector<std::pair<CallInst *, ClassQueryKind>, 16> ClassQueryCalls;
    SmallVector<std::pair<CallInst *, KlassQueryKind>, 16> KlassQueryCalls;
    SmallVector<CallInst *, 16> GetClassCalls;
    SmallVector<CallInst *, 16> LayoutHelperCalls;
    SmallVector<CallInst *, 16> KlassInitializedCalls;
    SmallVector<ICmpInst *, 16> ClassMirrorComparisons;
    SmallVector<LoadInst *, 16> Loads;
    for (BasicBlock *BB : RPOT) {
      for (Instruction &I : *BB) {
        if (auto *Call = dyn_cast<CallBase>(&I))
          collectKnownKlasses(*Call, KnownKlasses);
        if (auto *CI = dyn_cast<CallInst>(&I)) {
          if (jeandle::isStringGetChar(*CI))
            StringGetCharCalls.push_back(CI);
          if (isArrayLengthCall(CI))
            ArrayLengthCalls.push_back(CI);
          if (isLoadKlassCall(CI))
            LoadKlassCalls.push_back(CI);
          if (Function *Callee = CI->getCalledFunction();
              Callee && (Callee->getName() == "jeandle.check_instanceof" ||
                         Callee->getName() == "jeandle.check_klass_subtype"))
            ClassInstanceChecks.push_back(CI);
          if (isLoadMirrorKlassCall(CI))
            LoadMirrorKlassCalls.push_back(CI);
          if (auto Kind = classQueryKind(CI))
            ClassQueryCalls.emplace_back(CI, *Kind);
          if (auto Kind = getKlassQueryKind(CI))
            KlassQueryCalls.emplace_back(CI, *Kind);
          if (isGetClassCall(CI))
            GetClassCalls.push_back(CI);
          if (isLayoutHelperCall(CI))
            LayoutHelperCalls.push_back(CI);
          if (isKlassInitializedCall(CI))
            KlassInitializedCalls.push_back(CI);
        }
        if (auto *LI = dyn_cast<LoadInst>(&I))
          Loads.push_back(LI);
        if (auto *Cmp = dyn_cast<ICmpInst>(&I))
          ClassMirrorComparisons.push_back(Cmp);
      }
    }

    for (CallInst *CI : ArrayLengthCalls) {
      if (foldArrayLengthCall(CI, *CB, ConstOops, VMConsts)) {
        ++NumArrayLengthsFolded;
        RoundChanged = true;
        Changed = true;
      }
    }

    for (CallInst *CI : StringGetCharCalls) {
      if (foldStringGetCharCall(CI, *CB, ConstOops, VMConsts, LVI)) {
        ++NumStringCharsFolded;
        RoundChanged = true;
        Changed = true;
      }
    }

    // Fold object Klass loads before layout-helper queries so that a complete
    // constant-oop -> Klass* -> layout-helper chain collapses in one round.
    for (CallInst *CI : LoadKlassCalls) {
      if (CI->getParent() == nullptr)
        continue;
      if (foldLoadKlassCall(CI, *CB, ConstOops, DT, DL, IsNullEdge,
                            KnownKlasses, LVI)) {
        ++NumKlassesFolded;
        RoundChanged = true;
        Changed = true;
      }
    }

    for (CallInst *CI : LoadMirrorKlassCalls) {
      if (CI->getParent() == nullptr)
        continue;
      if (foldLoadMirrorKlassCall(CI, *CB, ConstOops, KnownKlasses)) {
        ++NumMirrorKlassesFolded;
        RoundChanged = true;
        Changed = true;
      }
    }

    for (ICmpInst *Cmp : ClassMirrorComparisons) {
      if (Cmp->getParent() == nullptr)
        continue;
      if (foldClassMirrorComparison(Cmp, *CB, ConstOops)) {
        RoundChanged = true;
        Changed = true;
      }
    }

    for (CallInst *CI : ClassInstanceChecks) {
      if (specializeConstantClassCheck(CI, *CB)) {
        RoundChanged = true;
        Changed = true;
      }
    }

    for (auto [CI, Kind] : ClassQueryCalls) {
      if (CI->getParent() == nullptr)
        continue;
      if (foldClassQueryCall(CI, Kind, *CB, VMConsts, ConstOops)) {
        RoundChanged = true;
        Changed = true;
      }
    }

    for (auto [CI, Kind] : KlassQueryCalls) {
      if (foldKlassQueryCall(CI, Kind, *CB, LVI, KnownKlasses)) {
        RoundChanged = true;
        Changed = true;
      }
    }

    for (CallInst *CI : GetClassCalls) {
      if (CI->getParent() == nullptr)
        continue;
      if (foldGetClassCall(CI, *CB, ConstOops, DT, DL, IsNullEdge, LVI)) {
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

      if (foldKlassFieldLoad(LI, *CB, KnownKlasses, DL)) {
        ++NumKlassFieldsFolded;
        RoundChanged = true;
        Changed = true;
        continue;
      }

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
