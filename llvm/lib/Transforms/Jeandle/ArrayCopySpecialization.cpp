//===- ArrayCopySpecialization.cpp - Jeandle arraycopy lowering -----------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/ArrayCopySpecialization.h"
#include "llvm/Analysis/LazyValueInfo.h"
#include "llvm/Analysis/TargetTransformInfo.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Jeandle/JavaType.h"
#include "llvm/IR/Jeandle/JeandleUtils.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMConstants.h"
#include "llvm/IR/MDBuilder.h"
#include "llvm/Transforms/Jeandle/JeandleTransformUtils.h"

#include <cassert>

using namespace llvm;

namespace {

#define PROB_MIN (1e-6f)
#define PROB_MAX (1.0f - 1e-6f)

constexpr uint32_t BranchWeightScale = 1000000;

// The jeandle.arraycopy pseudo operation carries offset and length operands
// in native arraycopy width. The real Java arraycopy stubs retain their
// existing i32 ABI and are adapted explicitly by toI32 below.
Value *toI32(IRBuilder<> &B, Value *V, const Twine &Name) {
  assert(V != nullptr && V->getType()->isIntegerTy() &&
         "arraycopy integer operand must be an integer");
  if (V->getType()->isIntegerTy(32))
    return V;
  return B.CreateTrunc(V, B.getInt32Ty(), Name);
}

bool isArrayCopyPseudoCall(CallBase &CB) {
  Function *Callee = CB.getCalledFunction();
  if (!Callee)
    return false;
  return Callee->getName() == "jeandle.arraycopy" && CB.arg_size() == 9;
}

StringRef arrayCopyKind(const CallBase &CI) {
  Attribute KindAttr = CI.getFnAttr(jeandle::Attribute::ArrayCopyKind);
  return KindAttr.isValid() ? KindAttr.getValueAsString() : StringRef();
}

bool isArrayCopy(const CallBase &CI) {
  return arrayCopyKind(CI) == jeandle::Attribute::ArrayCopyKindArrayCopy;
}

bool isArrayCopyValidated(const CallBase &CI) {
  return isArrayCopy(CI) &&
         CI.hasFnAttr(jeandle::Attribute::ValidatedArrayCopy);
}

bool isCopyOf(const CallBase &CI) {
  return arrayCopyKind(CI) == jeandle::Attribute::ArrayCopyKindCopyOf;
}

bool isCopyOfValidated(const CallBase &CI) {
  return isCopyOf(CI) &&
         CI.hasFnAttr(jeandle::Attribute::ValidatedArrayCopy);
}

bool isCopyOfRange(const CallBase &CI) {
  return arrayCopyKind(CI) ==
         jeandle::Attribute::ArrayCopyKindCopyOfRange;
}

bool isCopyOfRangeValidated(const CallBase &CI) {
  return isCopyOfRange(CI) &&
         CI.hasFnAttr(jeandle::Attribute::ValidatedArrayCopy);
}

bool isCloneInst(const CallBase &CI) {
  return arrayCopyKind(CI) == jeandle::Attribute::ArrayCopyKindCloneInst;
}

bool isCloneArray(const CallBase &CI) {
  return arrayCopyKind(CI) == jeandle::Attribute::ArrayCopyKindCloneArray;
}

bool isCloneOopArray(const CallBase &CI) {
  return arrayCopyKind(CI) == jeandle::Attribute::ArrayCopyKindCloneOopArray;
}

bool isCloneBasic(const CallBase &CI) {
  return isCloneInst(CI) || isCloneArray(CI);
}

bool hasNegativeLengthGuard(const CallBase &CI) {
  return CI.hasFnAttr(jeandle::Attribute::ArrayCopyNegativeLengthGuard);
}

bool isAllocTightlyCoupled(const CallBase &CI) {
  return CI.hasFnAttr(
      jeandle::Attribute::ArrayCopyTightlyCoupledAllocation);
}

struct PseudoCallFacts {
  CallBase *CB = nullptr;
  jeandle::JBasicType SrcElem = jeandle::JBasicType::Count;
  jeandle::JBasicType DestElem = jeandle::JBasicType::Count;
  std::optional<jeandle::CloneInstanceInfoResult> CloneInstanceInfo;
};

// Jeandle counterpart of C2's
// AllocateArrayNode::Ideal_array_allocation(ac->in(ArrayCopyNode::Dest)).
// The tightly-coupled-allocation attribute carries C2's ArrayCopyNode flag;
// this helper only recovers the allocation from the destination data edge.
CallBase *findTightlyCoupledArrayAllocation(CallBase &CI) {
  if (!isArrayCopy(CI) && !isCopyOf(CI) && !isCopyOfRange(CI) &&
      !isCloneOopArray(CI))
    return nullptr;

  Value *Dest = CI.getArgOperand(2)->stripPointerCasts();
  auto *Allocation = dyn_cast<CallBase>(Dest);
  Function *NewArray = CI.getModule()->getFunction("jeandle.new_array");
  if (Allocation == nullptr || NewArray == nullptr ||
      Allocation->getCalledOperand()->stripPointerCasts() != NewArray)
    return nullptr;

  return Allocation;
}

PseudoCallFacts analyzePseudoCall(CallBase &CB, DominatorTree &DT,
                                  jeandle::IsNullEdgeOracle IsNullEdge) {
  PseudoCallFacts Facts;
  Facts.CB = &CB;

  if (isArrayCopy(CB) || isCopyOfRange(CB) || isCopyOf(CB)) {
    const jeandle::JavaType SrcType =
        jeandle::getJavaType(CB.getArgOperand(0), &DT, &CB, IsNullEdge);
    const jeandle::JavaType DestType =
        jeandle::getJavaType(CB.getArgOperand(2), &DT, &CB, IsNullEdge);
    Facts.SrcElem = jeandle::elementTypeForArrayKlass(SrcType.Klass);
    Facts.DestElem = jeandle::elementTypeForArrayKlass(DestType.Klass);
  } else if (isCloneBasic(CB)) {
    const jeandle::JavaType SrcType =
        jeandle::getJavaType(CB.getArgOperand(0), &DT, &CB, IsNullEdge);
    if (isCloneArray(CB))
      Facts.SrcElem = jeandle::elementTypeForArrayKlass(SrcType.Klass);
    if (SrcType.isKnown()) {
      const jeandle::VMCallbacks *Callbacks = jeandle::getVMCallbacks();
      assert(Callbacks != nullptr &&
             Callbacks->GetCloneInstanceInfo != nullptr &&
             "clone-instance info callback must be registered");
      Facts.CloneInstanceInfo =
          Callbacks->GetCloneInstanceInfo(SrcType.Klass, SrcType.Exact);
    }
  } else {
    assert(isCloneOopArray(CB) && "unexpected arraycopy kind");
  }

  return Facts;
}

intptr_t getLengthIfConstant(CallBase &CI) {
  auto *Length = dyn_cast<ConstantInt>(CI.getArgOperand(4));
  if (Length == nullptr)
    return -1;

  assert((isCloneBasic(CI) || isArrayCopy(CI) || isCopyOf(CI) ||
          isCopyOfRange(CI)) &&
         "unexpected array copy type");

  // LLVM ConstantInt carries its bit width, so one signed extraction covers
  // C2's find_intptr_t_con() for clonebasic and find_int_con() for arraycopy.
  return static_cast<intptr_t>(Length->getSExtValue());
}

int arrayElementSizeInBytes(Module &M, jeandle::JBasicType ElemType) {
  assert(ElemType != jeandle::JBasicType::Count &&
         "unsupported array element basic type");
  const jeandle::VMConstants Constants = jeandle::VMConstants::fromModule(M);
  return static_cast<int>(Constants.elementSizeFor(ElemType));
}

int arrayBaseOffsetInBytes(Module &M, jeandle::JBasicType ElemType) {
  assert(ElemType != jeandle::JBasicType::Count &&
         "unsupported array element basic type");
  const jeandle::VMConstants Constants = jeandle::VMConstants::fromModule(M);
  return static_cast<int>(Constants.arrayBaseOffsetFor(ElemType));
}

Type *arrayElementStorageType(LLVMContext &Ctx, jeandle::JBasicType ElemType) {
  switch (ElemType) {
  case jeandle::JBasicType::Boolean:
  case jeandle::JBasicType::Byte:
    return Type::getInt8Ty(Ctx);
  case jeandle::JBasicType::Char:
  case jeandle::JBasicType::Short:
    return Type::getInt16Ty(Ctx);
  case jeandle::JBasicType::Int:
    return Type::getInt32Ty(Ctx);
  case jeandle::JBasicType::Long:
    return Type::getInt64Ty(Ctx);
  case jeandle::JBasicType::Float:
    return Type::getFloatTy(Ctx);
  case jeandle::JBasicType::Double:
    return Type::getDoubleTy(Ctx);
  case jeandle::JBasicType::Object:
  case jeandle::JBasicType::Count:
    return nullptr;
  }
  llvm_unreachable("unknown JBasicType");
}

bool isReferenceCopyType(jeandle::JBasicType BasicType) {
  return BasicType == jeandle::JBasicType::Object;
}

// JBasicType counterpart used by the arraycopy paths. Keep oop accesses
// pointer-typed so InsertGCBarriers can still recognize reference stores.
Type *arrayCopyStorageType(Module &M, jeandle::JBasicType BasicType) {
  if (isReferenceCopyType(BasicType)) {
    const int HeapOopBytes =
        arrayElementSizeInBytes(M, jeandle::JBasicType::Object);
    assert((HeapOopBytes == 4 || HeapOopBytes == 8) &&
           "heap oop size must be 4 or 8 bytes");
    const unsigned OopAddrSpace =
        HeapOopBytes == 4 ? jeandle::AddrSpace::NarrowOopAddrSpace
                          : jeandle::AddrSpace::JavaHeapAddrSpace;
    return PointerType::get(M.getContext(), OopAddrSpace);
  }
  return arrayElementStorageType(M.getContext(), BasicType);
}

LoadInst *load(IRBuilder<> &B, Value *Address,
               jeandle::JBasicType BasicType, const Twine &Name) {
  Module &M = *B.GetInsertBlock()->getModule();
  Type *StorageType = arrayCopyStorageType(M, BasicType);
  if (StorageType == nullptr)
    report_fatal_error("unsupported arraycopy load type");

  LoadInst *LoadedValue = B.CreateLoad(StorageType, Address, Name);
  LoadedValue->setVolatile(true);
  LoadedValue->setAtomic(AtomicOrdering::Unordered);
  return LoadedValue;
}

void store(IRBuilder<> &B, Value *Address, Value *StoredValue,
           jeandle::JBasicType BasicType) {
  Module &M = *B.GetInsertBlock()->getModule();
  Type *StorageType = arrayCopyStorageType(M, BasicType);
  if (StorageType == nullptr || StoredValue->getType() != StorageType)
    report_fatal_error("invalid arraycopy store type");

  StoreInst *Store = B.CreateStore(StoredValue, Address);
  Store->setAtomic(AtomicOrdering::Unordered);
}

bool isPrimitiveArrayElementType(jeandle::JBasicType ElemType) {
  return ElemType != jeandle::JBasicType::Count &&
         ElemType != jeandle::JBasicType::Object;
}

bool isSubwordArrayElementType(jeandle::JBasicType ElemType) {
  return ElemType == jeandle::JBasicType::Boolean ||
         ElemType == jeandle::JBasicType::Byte ||
         ElemType == jeandle::JBasicType::Char ||
         ElemType == jeandle::JBasicType::Short;
}

// Jeandle counterpart of
// C2 ArrayCopyNode::get_partial_inline_vector_lane_count().
int getPartialInlineVectorLaneCount(Module &M, jeandle::JBasicType Type,
                                    int ConstLen, int MaxInlineBytes) {
  const int ElementBytes = arrayElementSizeInBytes(M, Type);
  int LaneCount = MaxInlineBytes / ElementBytes;
  if (ConstLen > 0) {
    const int64_t SizeInBytes = static_cast<int64_t>(ConstLen) * ElementBytes;
    if (SizeInBytes <= 16)
      LaneCount = 16 / ElementBytes;
    else if (SizeInBytes <= 32)
      LaneCount = 32 / ElementBytes;
  }
  return LaneCount;
}

// Jeandle counterpart of C2 PhaseMacroExpand::array_element_address().
Value *arrayElementAddress(IRBuilder<> &B, Value *Ary, Value *Idx,
                           jeandle::JBasicType ElemType) {
  assert(Ary != nullptr && Idx != nullptr &&
         "array and index must be available");

  Module &M = *B.GetInsertBlock()->getModule();
  const int ElementBytes = arrayElementSizeInBytes(M, ElemType);
  assert(ElementBytes > 0 &&
         isPowerOf2_32(static_cast<uint32_t>(ElementBytes)) &&
         "array element size must be a positive power of two");
  const unsigned Shift =
      static_cast<unsigned>(Log2_32(static_cast<uint32_t>(ElementBytes)));
  const int Header = arrayBaseOffsetInBytes(M, ElemType);

  auto *IndexTy = cast<IntegerType>(Idx->getType());
  Value *Base = B.CreateGEP(
      B.getInt8Ty(), Ary, ConstantInt::get(IndexTy, Header),
      "arraycopy.element_base");
  Value *Scale = B.CreateShl(Idx, ConstantInt::get(IndexTy, Shift),
                             "arraycopy.element_scale");
  return B.CreateGEP(B.getInt8Ty(), Base, Scale, "arraycopy.element_address");
}

// Jeandle counterpart of C2 ArrayCopyNode::prepare_array_copy.
bool prepareArrayCopy(CallBase &CI, const PseudoCallFacts &Facts,
                      IRBuilder<> &B, Value *&AdrSrc, Value *&AdrDest,
                      jeandle::JBasicType &CopyType,
                      bool &DisjointBases) {
  AdrSrc = nullptr;
  AdrDest = nullptr;
  CopyType = jeandle::JBasicType::Count;
  DisjointBases = false;

  Value *BaseSrc = CI.getArgOperand(0);
  Value *SrcOffset = CI.getArgOperand(1);
  jeandle::JBasicType SrcElem = Facts.SrcElem;
  Value *BaseDest = CI.getArgOperand(2);
  Value *DestOffset = CI.getArgOperand(3);

 if (isArrayCopy(CI) || isCopyOfRange(CI) || isCopyOf(CI)) {
    jeandle::JBasicType DestElem = Facts.DestElem;

    if (isReferenceCopyType(SrcElem))
      SrcElem = jeandle::JBasicType::Object;
    if (isReferenceCopyType(DestElem))
      DestElem = jeandle::JBasicType::Object;

    DisjointBases = isAllocTightlyCoupled(CI);

    if (SrcElem == jeandle::JBasicType::Count ||
        DestElem == jeandle::JBasicType::Count) {
      // We don't know if arguments are arrays
      return false;
    }

    if (SrcElem != DestElem) {
      // We don't know if arguments are arrays of the same type
      return false;
    }

    // Jeandle currently takes a more conservative approach than C2: only
    // primitive copies are scalarized into loads/stores. Keep reference
    // copies on the bulk path so the collector's barriers are preserved.
    if (!isPrimitiveArrayElementType(DestElem))
      return false;

    // TODO: Retain the source element value_type for typed oop accesses and
    // model conv_I2X_index() TOP/out-of-range handling.

    CopyType = DestElem;
    AdrSrc = arrayElementAddress(B, BaseSrc, SrcOffset, CopyType);
    AdrDest = arrayElementAddress(B, BaseDest, DestOffset, CopyType);
  } else {
    assert(isCloneBasic(CI) && "unexpected arraycopy kind");
    assert(SrcElem != jeandle::JBasicType::Count &&
           "should be a clone array");

    DisjointBases = true;

    // Apply the same conservative policy to array clones.
    if (!isPrimitiveArrayElementType(SrcElem))
      return false;

    AdrSrc = B.CreateGEP(B.getInt8Ty(), BaseSrc, SrcOffset,
                         "clone.array.src");
    AdrDest = B.CreateGEP(B.getInt8Ty(), BaseDest, DestOffset,
                          "clone.array.dest");

    // The clone offsets point to the aligned raw-copy start. Scalarizing the
    // clone requires addresses at the first array element instead.
    auto *SrcOffsetConstant = dyn_cast<ConstantInt>(SrcOffset);
    assert(SrcOffsetConstant != nullptr &&
           "clone source offset must be constant");
    const int64_t Offset = SrcOffsetConstant->getSExtValue();
    const int64_t Diff = arrayBaseOffsetInBytes(*CI.getModule(), SrcElem) -
                         Offset;
    assert(Diff >= 0 && "clone should not start after first array element");
    if (Diff > 0) {
      Value *DiffValue = ConstantInt::get(
          cast<IntegerType>(SrcOffset->getType()), Diff);
      AdrSrc = B.CreateGEP(B.getInt8Ty(), AdrSrc, DiffValue,
                           "clone.array.src.element");
      AdrDest = B.CreateGEP(B.getInt8Ty(), AdrDest, DiffValue,
                            "clone.array.dest.element");
    }
    CopyType = SrcElem;
  }

  return true;
}

// Jeandle counterpart of C2 ArrayCopyNode::array_copy_test_overlap().
void arrayCopyTestOverlap(CallBase &CI, IRBuilder<> &B, bool DisjointBases,
                          int Count, BasicBlock *&ForwardCtl,
                          BasicBlock *&BackwardCtl) {
  BasicBlock *Ctl = B.GetInsertBlock();
  if (!DisjointBases && Count > 1) {
    Value *SrcOffset = CI.getArgOperand(1);
    Value *DestOffset = CI.getArgOperand(3);
    assert(SrcOffset != nullptr && DestOffset != nullptr &&
           "arraycopy offsets must be available");

    Function *F = Ctl->getParent();
    ForwardCtl =
        BasicBlock::Create(F->getContext(), "arraycopy.ideal.forward", F);
    BackwardCtl =
        BasicBlock::Create(F->getContext(), "arraycopy.ideal.backward", F);

    IRBuilder<> CtlBuilder(Ctl);
    Value *SrcBeforeDest = CtlBuilder.CreateICmpSLT(
        SrcOffset, DestOffset, "arraycopy.ideal.src_before_dest");
    CtlBuilder.CreateCondBr(SrcBeforeDest, BackwardCtl, ForwardCtl);
  } else {
    ForwardCtl = Ctl;
  }
}

// Jeandle counterpart of C2 ArrayCopyNode::array_copy_forward().
void arrayCopyForward(BasicBlock *ForwardCtl, jeandle::JBasicType CopyType,
                      Value *AdrSrc, Value *AdrDest, int Count) {
  if (ForwardCtl == nullptr)
    return;

  IRBuilder<> B(ForwardCtl);
  Type *AccessType =
      arrayCopyStorageType(*ForwardCtl->getModule(), CopyType);
  assert(AccessType != nullptr && "unsupported arraycopy load/store type");

  if (Count > 0) {
    Value *LoadedValue = load(B, AdrSrc, CopyType, "arraycopy.load");
    store(B, AdrDest, LoadedValue, CopyType);

    for (int I = 1; I < Count; ++I) {
      Value *NextSrc = B.CreateInBoundsGEP(AccessType, AdrSrc, B.getInt64(I),
                                           "arraycopy.forward.src");
      Value *NextDest = B.CreateInBoundsGEP(AccessType, AdrDest, B.getInt64(I),
                                            "arraycopy.forward.dest");
      LoadedValue = load(B, NextSrc, CopyType, "arraycopy.load");
      store(B, NextDest, LoadedValue, CopyType);
    }
  } else {
    assert(Count == 0 && "arraycopy count must not be negative");
    // LLVM dead-code elimination removes the unused address calculations.
  }
}

// Jeandle counterpart of C2 ArrayCopyNode::array_copy_backward().
void arrayCopyBackward(BasicBlock *BackwardCtl, jeandle::JBasicType CopyType,
                       Value *AdrSrc, Value *AdrDest, int Count) {
  if (BackwardCtl == nullptr)
    return;

  IRBuilder<> B(BackwardCtl);
  Type *AccessType =
      arrayCopyStorageType(*BackwardCtl->getModule(), CopyType);
  assert(AccessType != nullptr && "unsupported arraycopy load/store type");

  for (int I = Count - 1; I >= 0; --I) {
    Value *SrcAddress = AdrSrc;
    Value *DestAddress = AdrDest;
    if (I != 0) {
      SrcAddress = B.CreateInBoundsGEP(AccessType, AdrSrc, B.getInt64(I),
                                       "arraycopy.backward.src");
      DestAddress = B.CreateInBoundsGEP(AccessType, AdrDest, B.getInt64(I),
                                        "arraycopy.backward.dest");
    }
    Value *LoadedValue =
        load(B, SrcAddress, CopyType, "arraycopy.load");
    store(B, DestAddress, LoadedValue, CopyType);
  }
}

// Jeandle counterpart of C2 Phase::gen_subtype_check(). The subtype
// calculation is implemented by the jeandle.check_klass_subtype JavaOp in
// template.ll; this helper only creates its caller-side control projections.
BasicBlock *genSubtypeCheck(IRBuilder<> &B, Module &M, BasicBlock *&ControlBB,
                            Value *SubKlass, Value *SuperKlass) {
  LLVMContext &Ctx = M.getContext();
  BasicBlock *SubtypeHeadBB = ControlBB;
  Function *F = SubtypeHeadBB->getParent();
  BasicBlock *SubtypePassBB = BasicBlock::Create(
      Ctx, "arraycopy.subtype.pass", F, SubtypeHeadBB->getNextNode());
  BasicBlock *NotSubtypeCtrl =
      BasicBlock::Create(Ctx, "arraycopy.not_subtype", F, SubtypePassBB);

  IRBuilder<> SubtypeBuilder(SubtypeHeadBB);
  Function *CheckKlassSubtype = M.getFunction("jeandle.check_klass_subtype");
  assert(CheckKlassSubtype != nullptr && "invalid JavaOp");
  CallInst *IsSubtype = SubtypeBuilder.CreateCall(
      CheckKlassSubtype, {SubKlass, SuperKlass}, "arraycopy.subtype_check");
  IsSubtype->setCallingConv(CallingConv::Hotspot_JIT);

  SubtypeBuilder.CreateCondBr(IsSubtype, SubtypePassBB, NotSubtypeCtrl);

  ControlBB = SubtypePassBB;
  B.SetInsertPoint(SubtypePassBB);
  return NotSubtypeCtrl;
}

// Jeandle counterpart of C2 ArrayCopyNode::get_count().
int getCount(
    CallBase &CI,
    const std::optional<jeandle::CloneInstanceInfoResult> &CloneInstanceInfo) {
  if (isCloneBasic(CI)) {
    if (!CloneInstanceInfo.has_value())
      return -1;

    const auto &Info = *CloneInstanceInfo;
    const auto Status = static_cast<jeandle::CloneInstanceInfoStatus>(
        std::get<0>(Info));
    if (Status != jeandle::CloneInstanceInfoStatus::NotInstance)
      return std::get<1>(Info);

    // TODO: Match C2's constant array-length clone count calculation.
    return -1;
  }

  return getLengthIfConstant(CI);
}

void eraseArrayCopyPseudoCall(CallBase &CI) {
  assert(CI.getType()->isVoidTy() && CI.use_empty() &&
         "arraycopy pseudo call must not produce a value");
  if (auto *Invoke = dyn_cast<InvokeInst>(&CI)) {
    BasicBlock *Parent = Invoke->getParent();
    BasicBlock *NormalDest = Invoke->getNormalDest();
    BasicBlock *UnwindDest = Invoke->getUnwindDest();
    UnwindDest->removePredecessor(Parent);
    Invoke->eraseFromParent();
    BranchInst::Create(NormalDest, Parent);
    return;
  }
  CI.eraseFromParent();
}

// Jeandle counterpart of C2 ArrayCopyNode::try_clone_instance(). LLVM has no
// explicit memory Node to return, so preserve C2's return states as:
// nullopt == not an instance clone, false == declined, true == transformed.
std::optional<bool> tryCloneInstance(
    CallBase &CI,
    const std::optional<jeandle::CloneInstanceInfoResult> &CloneInstanceInfo) {
  if (!isCloneBasic(CI))
    return std::nullopt;

  assert(CloneInstanceInfo.has_value() &&
         "clone-instance info must be available");

  const auto &Info = *CloneInstanceInfo;
  Value *BaseSrc = CI.getArgOperand(0);
  Value *BaseDest = CI.getArgOperand(2);
  const int StatusValue = std::get<0>(Info);
  const auto &Fields = std::get<2>(Info);
  const auto Status =
      static_cast<jeandle::CloneInstanceInfoStatus>(StatusValue);
  switch (Status) {
  case jeandle::CloneInstanceInfoStatus::NotInstance:
    return std::nullopt;
  case jeandle::CloneInstanceInfoStatus::NotApplicable:
  case jeandle::CloneInstanceInfoStatus::TransformFailed:
    return false;
  case jeandle::CloneInstanceInfoStatus::RequiresGCBarriers:
    // Leave the pseudo call for the collector-specific bulk expansion. G1 may
    // replace it with its barrier-aware runtime clone.
    return false;
  case jeandle::CloneInstanceInfoStatus::Ready:
    break;
  default:
    report_fatal_error("invalid clone-instance callback status");
  }

  IRBuilder<> B(&CI);
  for (const auto &[Offset, TypeValue] : Fields) {
    const auto BasicType = static_cast<jeandle::JBasicType>(TypeValue);
    if (BasicType >= jeandle::JBasicType::Count)
      report_fatal_error("invalid clone-instance field basic type");
    if (Offset < 0)
      report_fatal_error("invalid clone-instance field description");

    Value *OffsetValue = B.getInt64(Offset);
    Value *SrcAddress = B.CreateInBoundsGEP(
        B.getInt8Ty(), BaseSrc, OffsetValue, "clone.instance.src");
    Value *DestAddress = B.CreateInBoundsGEP(
        B.getInt8Ty(), BaseDest, OffsetValue, "clone.instance.dest");
    Value *LoadedValue =
        load(B, SrcAddress, BasicType, "clone.instance.load");
    store(B, DestAddress, LoadedValue, BasicType);
  }

  // LLVM control flow already represents C2's merged control and memory. Oop
  // fields retain their pointer address space so InsertGCBarriers can process
  // them later. TODO: propagate the tightly-coupled allocation property so
  // that pass can omit the unnecessary pre-barrier and, when
  // ReduceInitialCardMarks is enabled, the post-barrier as well.
  eraseArrayCopyPseudoCall(CI);
  return true;
}

// Jeandle equivalent of C2 ArrayCopyNode::Ideal().
bool arrayCopyIdeal(CallBase &CI, const PseudoCallFacts &Facts) {
  assert(isArrayCopyPseudoCall(CI) && "should be an arraycopy");

  // See if it's a small array copy and we can inline it as
  // loads/stores
  // Here we can only do:
  // - arraycopy if all arguments were validated before and we don't
  // need card marking
  // - clone for which we don't need to do card marking
  if (!isCloneBasic(CI) && !isArrayCopyValidated(CI) &&
      !isCopyOfRangeValidated(CI) && !isCopyOfValidated(CI))
    return false;

  Module *M = CI.getModule();
  const jeandle::VMConstants VMConsts = jeandle::VMConstants::fromModule(*M);
  const int MaxElem = static_cast<int>(VMConsts.arrayCopyLoadStoreMaxElem());

  int Count = getCount(CI, Facts.CloneInstanceInfo);
  if (Count < 0 || Count > MaxElem)
    return false;

  std::optional<bool> CloneResult =
      tryCloneInstance(CI, Facts.CloneInstanceInfo);
  if (CloneResult.has_value())
    return *CloneResult;

  // The generic ideal path below rewrites the invoke's exceptional edges.
  // A call-form pseudo site has none, but an instance clone above can still
  // be scalarized without any CFG rewrite.
  if (!isa<InvokeInst>(CI))
    return false;

  IRBuilder<> B(&CI);
  Value *AdrSrc = nullptr;
  Value *AdrDest = nullptr;
  jeandle::JBasicType CopyType = jeandle::JBasicType::Count;
  bool DisjointBases = false;
  if (!prepareArrayCopy(CI, Facts, B, AdrSrc, AdrDest, CopyType,
                        DisjointBases)) {
    assert(AdrSrc == nullptr && "no address can be left behind");
    assert(AdrDest == nullptr && "no address can be left behind");
    return false;
  }

  BasicBlock *Ctl = CI.getParent();
  BasicBlock *ResultCtl =
      Ctl->splitBasicBlock(CI.getIterator(), "arraycopy.ideal.result");
  Ctl->getTerminator()->eraseFromParent();
  B.SetInsertPoint(Ctl);

  InvokeInst &Invoke = cast<InvokeInst>(CI);

  BasicBlock *ForwardCtl = nullptr;
  BasicBlock *BackwardCtl = nullptr;
  arrayCopyTestOverlap(CI, B, DisjointBases, Count, ForwardCtl, BackwardCtl);

  arrayCopyForward(ForwardCtl, CopyType, AdrSrc, AdrDest, Count);
  arrayCopyBackward(BackwardCtl, CopyType, AdrSrc, AdrDest, Count);

  if (ForwardCtl != nullptr)
    BranchInst::Create(ResultCtl, ForwardCtl);
  if (BackwardCtl != nullptr)
    BranchInst::Create(ResultCtl, BackwardCtl);

  BasicBlock *NormalCtl = Invoke.getNormalDest();
  BasicBlock *ExceptionCtl = Invoke.getUnwindDest();
  ExceptionCtl->removePredecessor(ResultCtl);
  Invoke.eraseFromParent();
  BranchInst::Create(NormalCtl, ResultCtl);

  return true;
}

CallInst *makeLeafCall(IRBuilder<> &B, Module &M, FunctionType *CallTy,
                       StringRef CallName, ArrayRef<Value *> Params,
                       const Twine &Name = "") {
  Function *Callee = M.getFunction(CallName);
  if (Callee == nullptr)
    return nullptr;
  assert(Callee->getFunctionType() == CallTy &&
         "leaf call declaration type mismatch");
  assert(Params.size() == CallTy->getNumParams() &&
         "leaf call argument count mismatch");

  // Keep call sites in the native-width arraycopy representation and adapt
  // only integer widths required by the selected leaf stub declaration. This
  // centralizes the i64-to-i32 conversion for the generic arraycopy stub
  // without weakening pointer/address-space type checking.
  SmallVector<Value *, 8> CallArgs;
  CallArgs.reserve(Params.size());
  for (unsigned I = 0; I < Params.size(); ++I) {
    Value *Arg = Params[I];
    Type *Expected = CallTy->getParamType(I);
    if (Arg->getType() != Expected) {
      assert(Arg->getType()->isIntegerTy() && Expected->isIntegerTy() &&
             "leaf call argument type mismatch");
      Arg = B.CreateIntCast(Arg, Expected, true,
                            Twine(CallName) + ".arg" + Twine(I));
    }
    CallArgs.push_back(Arg);
  }

  CallInst *Call = B.CreateCall(Callee, CallArgs, Name);
  Call->setCallingConv(CallingConv::C);
  Call->addFnAttr(Attribute::NoUnwind);
  Call->addFnAttr(Attribute::get(B.getContext(), "gc-leaf-function"));
  // TODO: Add precise LLVM memory effects or AA metadata if alias-analysis
  // evidence shows that arraycopy dependencies block optimization. Do not
  // infer noalias from the element BasicType: source and destination may
  // overlap, and oop copies also interact with GC barriers.
  return Call;
}

// Emit the platform-specific StoreStore JavaOp when the full Jeandle template
// module is available. Standalone LLVM tests do not contain the architecture
// template, so retain a conservative SeqCst fence as a self-contained
// fallback. The JavaOp is lowered by JavaOperationLower(1) later in the
// Jeandle pipeline.
void emitStoreStoreBarrier(IRBuilder<> &B, Module &M) {
  Function *StoreStore = M.getFunction("jeandle.membar_storestore");
  if (StoreStore != nullptr && !StoreStore->isDeclaration()) {
    CallInst *Call = B.CreateCall(StoreStore, {});
    Call->setCallingConv(CallingConv::Hotspot_JIT);
    return;
  }

  B.CreateFence(AtomicOrdering::SequentiallyConsistent);
}

// Jeandle counterpart of C2 BarrierSetC2::clone_at_expansion().
void cloneAtExpansion(CallBase &CI) {
  assert(isCloneBasic(CI) && "must be a clonebasic arraycopy");

  Value *Src = CI.getArgOperand(0);
  Value *SrcOffset = CI.getArgOperand(1);
  Value *Dest = CI.getArgOperand(2);
  Value *DestOffset = CI.getArgOperand(3);
  Value *Length = CI.getArgOperand(4);

  IRBuilder<> B(&CI);
  Module &M = *CI.getModule();
  Function *CloneAtExpansion = M.getFunction("jeandle.clone_at_expansion");
  assert(CloneAtExpansion != nullptr && !CloneAtExpansion->isDeclaration() &&
         "clone-at-expansion JavaOp must be defined");
  CallInst *Expansion = B.CreateCall(
      CloneAtExpansion,
      {Src, SrcOffset, Dest, DestOffset, Length, B.getInt1(isCloneInst(CI))});
  Expansion->setCallingConv(CallingConv::Hotspot_JIT);

  // Publication ordering is emitted by the frontend's copy_to_clone() and
  // remains in place when this pass replaces the clone pseudo call.

  eraseArrayCopyPseudoCall(CI);
}

//------------------------------generateGuard---------------------------
// Helper function for generating guarded fast-slow graph structures. The given
// Test, if true, guards a slow path. If the test fails then the fast path is
// taken. In all cases, ControlBB is updated to the fast path. The returned
// value represents the control for the slow path, or null if the slow path can
// never be taken.
BasicBlock *generateGuard(BasicBlock *&ControlBB, Value *Test,
                          BasicBlock *SlowBB, StringRef Prefix,
                          CallBase *BeforeCall, float TrueProb) {
  if (ControlBB == nullptr)
    return nullptr;
  if (auto *C = dyn_cast<ConstantInt>(Test)) {
    if (C->isZero())
      return nullptr;
  }

  Function *F = ControlBB->getParent();
  BasicBlock *HeadBB = ControlBB;
  BasicBlock *FastBB = nullptr;
  if (BeforeCall != nullptr) {
    assert(BeforeCall->getParent() == HeadBB &&
           "guard must split the current control block");
    if (HeadBB->getTerminator() != nullptr) {
      FastBB = HeadBB->splitBasicBlock(BeforeCall->getIterator(),
                                       Twine(Prefix) + ".fast");
      HeadBB->getTerminator()->eraseFromParent();
    } else {
      FastBB = BasicBlock::Create(F->getContext(), Twine(Prefix) + ".fast", F,
                                  HeadBB->getNextNode());
      FastBB->splice(FastBB->end(), HeadBB, BeforeCall->getIterator(),
                     HeadBB->end());
    }
  } else {
    FastBB =
        BasicBlock::Create(F->getContext(), Twine(Prefix) + ".fast", F, SlowBB);
  }

  if (SlowBB == nullptr)
    SlowBB = BasicBlock::Create(F->getContext(), Prefix, F, FastBB);

  IRBuilder<> B(HeadBB);
  BranchInst *Guard = B.CreateCondBr(Test, SlowBB, FastBB);
  assert(TrueProb > 0.0f && TrueProb < 1.0f &&
         "branch probability must be in (0, 1)");
  uint32_t TrueWeight = static_cast<uint32_t>(TrueProb * BranchWeightScale);
  assert(TrueWeight > 0 && TrueWeight < BranchWeightScale &&
         "branch probability must map to non-zero branch weights");
  uint32_t FalseWeight = BranchWeightScale - TrueWeight;
  MDBuilder MDB(F->getContext());
  Guard->setMetadata(LLVMContext::MD_prof,
                     MDB.createBranchWeights(TrueWeight, FalseWeight));

  ControlBB = FastBB;
  return SlowBB;
}

void generateNegativeGuard(BasicBlock *&ControlBB, Value *Index,
                           BasicBlock *SlowBB, StringRef Prefix,
                           CallBase *BeforeCall = nullptr) {
  if (ControlBB == nullptr)
    return;
  IRBuilder<> B(ControlBB);
  if (BeforeCall != nullptr)
    B.SetInsertPoint(BeforeCall);
  Value *IsNegative =
      B.CreateICmpSLT(Index, ConstantInt::get(Index->getType(), 0),
                      Twine(Prefix) + ".is_negative");
  generateGuard(ControlBB, IsNegative, SlowBB, Prefix, BeforeCall, PROB_MIN);
}

void generateLimitGuard(BasicBlock *&ControlBB, Value *Offset, Value *SubseqLength,
                        Value *ArrayLength, BasicBlock *SlowBB,
                        StringRef Prefix, CallBase *BeforeCall = nullptr) {
  IRBuilder<> B(ControlBB);
  if (BeforeCall != nullptr)
    B.SetInsertPoint(BeforeCall);

  auto *ConstantOffset = dyn_cast<ConstantInt>(Offset);
  const bool ZeroOffset = ConstantOffset != nullptr && ConstantOffset->isZero();
  if (ZeroOffset && SubseqLength == ArrayLength)
    return;

  Value *Last = SubseqLength;
  if (!ZeroOffset) {
    Last = B.CreateAdd(Last, Offset, Twine(Prefix) + ".last");
  }
  Value *ExceedsLimit = B.CreateICmpULT(ArrayLength, Last, Twine(Prefix) + ".exceeds_limit");
  generateGuard(ControlBB, ExceedsLimit, SlowBB, Prefix, BeforeCall, PROB_MIN);
}

void generatePartialInliningBlock(BasicBlock *&ControlBB, BasicBlock *&ExitBB,
                                  jeandle::JBasicType BasicType, Value *SrcAddr,
                                  Value *DestAddr, Value *Length64,
                                  int MaxInlineBytes,
                                  TargetTransformInfo &TTI) {
  assert(ControlBB != nullptr && "arraycopy control must be live");

  Type *ElemTy = arrayElementStorageType(ControlBB->getContext(), BasicType);
  assert(ElemTy != nullptr && "partial inlining requires a subword type");

  Module &M = *ControlBB->getParent()->getParent();
  const int ElementBytes = arrayElementSizeInBytes(M, BasicType);
  assert(ElementBytes > 0 &&
         isPowerOf2_32(static_cast<uint32_t>(ElementBytes)) &&
         "array element size must be a positive power of two");
  const int Log2ElementSize =
      static_cast<int>(Log2_32(static_cast<uint32_t>(ElementBytes)));

  int ConstLen = -1;
  if (auto *ConstLength = dyn_cast<ConstantInt>(Length64))
    ConstLen = static_cast<int>(ConstLength->getSExtValue());

  // Avoid constructing an inline/stub split when a compile-time length is
  // already outside the partial-inline limit.
  int64_t ConstBytes = -1;
  if (ConstLen >= 0)
    ConstBytes = static_cast<int64_t>(ConstLen) << Log2ElementSize;
  if (MaxInlineBytes <= 0 || ConstBytes > MaxInlineBytes)
    return;

  const int LaneCount =
      getPartialInlineVectorLaneCount(M, BasicType, ConstLen, MaxInlineBytes);
  if (LaneCount <= 0 || LaneCount * ElementBytes < 16)
    return;

  const unsigned VectorLaneCount = static_cast<unsigned>(LaneCount);

  // Matcher::match_rule_supported_vector() is C2-specific.  The equivalent
  // LLVM target check is whether masked load/store remain legal vector
  // operations.  If not, keep the normal arraycopy stub path rather than
  // creating a partial-inline path that LLVM would scalarize.
  auto *VecTy = FixedVectorType::get(ElemTy, VectorLaneCount);
  const auto *SrcPtrTy = dyn_cast<PointerType>(SrcAddr->getType());
  const auto *DestPtrTy = dyn_cast<PointerType>(DestAddr->getType());
  if (SrcPtrTy == nullptr || DestPtrTy == nullptr ||
      !TTI.isLegalMaskedLoad(VecTy, Align(1), SrcPtrTy->getAddressSpace()) ||
      !TTI.isLegalMaskedStore(VecTy, Align(1), DestPtrTy->getAddressSpace()))
    return;

  LLVMContext &Ctx = ControlBB->getContext();
  BasicBlock *Head = ControlBB;
  Function *F = Head->getParent();

  // Match C2 generate_partial_inlining_block(): split the current control into
  // an inline block and a stub block, pre-initialize the exit block with the
  // inline edge, and leave ControlBB on the stub edge so the caller can
  // generate the normal unchecked arraycopy call and connect the remaining exit
  // edge.
  ExitBB = BasicBlock::Create(Ctx, "arraycopy.partial.exit", F);
  BasicBlock *InlineBB =
      BasicBlock::Create(Ctx, "arraycopy.partial.inline", F, ExitBB);
  BasicBlock *StubBB =
      BasicBlock::Create(Ctx, "arraycopy.partial.stub", F, ExitBB);

  IRBuilder<> HeadBuilder(Head);
  Value *CopyBytes = Length64;
  if (Log2ElementSize != 0)
    CopyBytes = HeadBuilder.CreateShl(Length64, Log2ElementSize,
                                      "arraycopy.partial.bytes");
  Value *InlineCopy =
      HeadBuilder.CreateICmpULE(CopyBytes, HeadBuilder.getInt64(MaxInlineBytes),
                                "arraycopy.partial.inline_ok");
  BranchInst *Guard = HeadBuilder.CreateCondBr(InlineCopy, InlineBB, StubBB);
  MDBuilder MDB(Ctx);
  Guard->setMetadata(LLVMContext::MD_prof, MDB.createBranchWeights(1, 1));

  IRBuilder<> InlineBuilder(InlineBB);
  Type *MaskBitsTy = InlineBuilder.getIntNTy(VectorLaneCount);
  Value *LengthBits = InlineBuilder.CreateZExtOrTrunc(
      Length64, MaskBitsTy, "arraycopy.partial.length_bits");
  Value *AllBits = ConstantInt::getAllOnesValue(MaskBitsTy);
  Value *MaskBits = InlineBuilder.CreateLShr(
      AllBits,
      InlineBuilder.CreateSub(ConstantInt::get(MaskBitsTy, VectorLaneCount),
                              LengthBits, "arraycopy.partial.inactive_lanes"),
      "arraycopy.partial.mask_bits");
  Value *Mask = InlineBuilder.CreateBitCast(
      MaskBits,
      FixedVectorType::get(InlineBuilder.getInt1Ty(), VectorLaneCount),
      "arraycopy.partial.mask");
  CallInst *MaskedLoad = InlineBuilder.CreateMaskedLoad(
      VecTy, SrcAddr, Align(1), Mask, nullptr, "arraycopy.partial.load");
  InlineBuilder.CreateMaskedStore(MaskedLoad, DestAddr, Align(1), Mask);
  InlineBuilder.CreateBr(ExitBB);

  ControlBB = StubBB;
}

BasicBlock *generateNonpositiveGuard(BasicBlock *&ControlBB, Value *CopyLength,
                                     bool LengthNeverNegative) {
  if (ControlBB == nullptr)
    return nullptr;

  // TODO: Match C2s _igvn.type(index)->higher_equal(TypeInt::POS1)
  // precisely by consulting LLVM range information or dominating guard facts.
  // This constant-only check covers only the parse-time constant subset.
  auto *Length = dyn_cast<ConstantInt>(CopyLength);
  if (Length != nullptr && Length->getSExtValue() > 0)
    return nullptr;

  IRBuilder<> B(ControlBB);
  Value *Zero = ConstantInt::get(CopyLength->getType(), 0);
  Value *IsNotPositive =
      LengthNeverNegative
          ? B.CreateICmpEQ(CopyLength, Zero, "arraycopy.length_is_zero")
          : B.CreateICmpSLE(CopyLength, Zero,
                            "arraycopy.length_is_not_positive");
  return generateGuard(ControlBB, IsNotPositive, nullptr,
                       "arraycopy.nonpositive", nullptr, PROB_MIN);
}

CallInst *generateGenericArrayCopy(Module &M, Value *Src, Value *SrcPos,
                                   Value *Dest, Value *DestPos, Value *Length,
                                   BasicBlock *&ControlBB) {
  if (ControlBB == nullptr)
    return nullptr;

  Function *CopyFunc = M.getFunction("StubRoutines_generic_arraycopy");
  if (CopyFunc == nullptr) { // Stub was not generated, go slow path.
    return nullptr;
  }

  IRBuilder<> CopyBuilder(ControlBB);
  FunctionType *GenericTy = FunctionType::get(
      CopyBuilder.getInt32Ty(),
      {Src->getType(), CopyBuilder.getInt32Ty(), Dest->getType(),
       CopyBuilder.getInt32Ty(), CopyBuilder.getInt32Ty()},
      false);
  CallInst *Result = makeLeafCall(
      CopyBuilder, M, GenericTy, "StubRoutines_generic_arraycopy",
      {Src, SrcPos, Dest, DestPos, Length}, "arraycopy.generic.result");
  return Result;
}

CallBase *generateSlowArrayCopy(IRBuilder<> &B, Module &M, CallBase &StateCall,
                                Value *Src, Value *SrcPos, Value *Dest,
                                Value *DestPos, Value *Length) {
  Function *Slow = M.getFunction("SharedRuntime_slow_arraycopy_C");
  assert(Slow != nullptr &&
         "slow arraycopy runtime declaration must be available");
  NamedMDNode *ThreadRegister =
      M.getNamedMetadata(jeandle::Metadata::CurrentThread);
  assert(ThreadRegister != nullptr && "current_thread metadata must exist");
  Value *ReadRegisterArgs[] = {
      MetadataAsValue::get(M.getContext(), ThreadRegister->getOperand(0))};
  Value *ThreadValue = B.CreateIntrinsic(
      Intrinsic::read_register, B.getIntPtrTy(M.getDataLayout()),
      ReadRegisterArgs, {} /* FMFSource */, "arraycopy.current_thread_value");
  Value *Thread = B.CreateIntToPtr(
      ThreadValue,
      PointerType::get(M.getContext(), jeandle::AddrSpace::CHeapAddrSpace),
      "arraycopy.current_thread");

  Value *SrcPosI32 = toI32(B, SrcPos, "arraycopy.slow.src_pos_i32");
  Value *DestPosI32 = toI32(B, DestPos, "arraycopy.slow.dest_pos_i32");
  Value *LengthI32 = toI32(B, Length, "arraycopy.slow.length_i32");
  SmallVector<Value *, 6> Args = {Src, SrcPosI32, Dest, DestPosI32,
                                  LengthI32, Thread};
  InvokeInst &StateInvoke = cast<InvokeInst>(StateCall);
  SmallVector<OperandBundleDef, 1> Bundles;
  StateInvoke.getOperandBundlesAsDefs(Bundles);
  assert(!Bundles.empty() &&
         "throwing arraycopy pseudo call must carry JVM state");
  CallBase *SlowCall =
      B.CreateInvoke(Slow, StateInvoke.getNormalDest(),
                     StateInvoke.getUnwindDest(), Args, Bundles);
  SlowCall->setCallingConv(CallingConv::Hotspot_JIT);
  return SlowCall;
}

CallInst *generateCheckcastArrayCopy(BasicBlock *&ControlBB,
                                     Value *DestElemKlass, Value *Src,
                                     Value *SrcPos, Value *Dest, Value *DestPos,
                                     Value *CopyLength,
                                     bool DestUninitialized) {
  if (ControlBB == nullptr)
    return nullptr;

  Function *F = ControlBB->getParent();
  Module &M = *F->getParent();
  LLVMContext &Ctx = M.getContext();
  IRBuilder<> B(ControlBB);
  Type *I64 = B.getInt64Ty();
  Type *I32 = B.getInt32Ty();
  Type *KlassTy = PointerType::get(Ctx, jeandle::AddrSpace::CHeapAddrSpace);

  StringRef CopyName = DestUninitialized
                           ? "StubRoutines_checkcast_arraycopy_uninit"
                           : "StubRoutines_checkcast_arraycopy";
  Function *CopyFunc = M.getFunction(CopyName);
  if (CopyFunc == nullptr) // Stub was not generated, go slow path.
    return nullptr;

  GlobalVariable *SuperCheckOffsetOffsetGlobal =
      M.getGlobalVariable("Klass.super_check_offset_offset", true);
  Value *SuperCheckOffsetOffset =
      B.CreateLoad(B.getInt32Ty(), SuperCheckOffsetOffsetGlobal,
                   "arraycopy.super_check_offset_offset");
  Value *SuperCheckOffsetAddr =
      B.CreateInBoundsGEP(B.getInt8Ty(), DestElemKlass, SuperCheckOffsetOffset,
                          "arraycopy.super_check_offset_addr");
  Value *CheckOffset = B.CreateLoad(B.getInt32Ty(), SuperCheckOffsetAddr,
                                    "arraycopy.super_check_offset");
  CheckOffset =
      B.CreateZExtOrTrunc(CheckOffset, I64, "arraycopy.checkcast.offset64");

  Value *SrcStart =
      arrayElementAddress(B, Src, SrcPos, jeandle::JBasicType::Object);
  Value *DestStart =
      arrayElementAddress(B, Dest, DestPos, jeandle::JBasicType::Object);

  FunctionType *StubTy = FunctionType::get(
      I32, {SrcStart->getType(), DestStart->getType(), I64, I64, KlassTy},
      false);
  CallInst *Call = makeLeafCall(
      B, M, StubTy, CopyName,
      {SrcStart, DestStart, CopyLength, CheckOffset, DestElemKlass},
      "arraycopy.checkcast.result");
  return Call;
}

// Jeandle counterpart of C2 PhaseMacroExpand::basictype2arraycopy().
Function *basicTypeToArrayCopy(Module &M, jeandle::JBasicType BasicType,
                               Value *SrcOffset, Value *DestOffset,
                               bool DisjointBases, StringRef &Name,
                               bool DestUninitialized) {
  bool Aligned = false;
  bool Disjoint = DisjointBases;

  auto *SrcOffsetConstant = dyn_cast_or_null<ConstantInt>(SrcOffset);
  auto *DestOffsetConstant = dyn_cast_or_null<ConstantInt>(DestOffset);
  if (SrcOffsetConstant != nullptr && DestOffsetConstant != nullptr) {
    const int64_t SrcOffsetValue = SrcOffsetConstant->getSExtValue();
    const int64_t DestOffsetValue = DestOffsetConstant->getSExtValue();
    const int ElementSize = arrayElementSizeInBytes(M, BasicType);
    const int Header = arrayBaseOffsetInBytes(M, BasicType);
    GlobalVariable *WordSizeGlobal = M.getGlobalVariable("WordSize", true);
    assert(WordSizeGlobal != nullptr && WordSizeGlobal->hasInitializer() &&
           "word size must be available");
    auto *WordSizeConstant =
        dyn_cast<ConstantInt>(WordSizeGlobal->getInitializer());
    assert(WordSizeConstant != nullptr && "word size must be constant");
    const int64_t WordSize = WordSizeConstant->getSExtValue();
    Aligned = (Header + SrcOffsetValue * ElementSize) % WordSize == 0 &&
              (Header + DestOffsetValue * ElementSize) % WordSize == 0;
    if (SrcOffsetValue >= DestOffsetValue)
      Disjoint = true;
  } else if (SrcOffset != nullptr && SrcOffset == DestOffset) {
    Disjoint = true;
  }

  switch (BasicType) {
  case jeandle::JBasicType::Boolean:
  case jeandle::JBasicType::Byte:
    if (Aligned)
      Name = Disjoint ? "StubRoutines_arrayof_jbyte_disjoint_arraycopy"
                      : "StubRoutines_arrayof_jbyte_arraycopy";
    else
      Name = Disjoint ? "StubRoutines_jbyte_disjoint_arraycopy"
                      : "StubRoutines_jbyte_arraycopy";
    break;
  case jeandle::JBasicType::Char:
  case jeandle::JBasicType::Short:
    if (Aligned)
      Name = Disjoint ? "StubRoutines_arrayof_jshort_disjoint_arraycopy"
                      : "StubRoutines_arrayof_jshort_arraycopy";
    else
      Name = Disjoint ? "StubRoutines_jshort_disjoint_arraycopy"
                      : "StubRoutines_jshort_arraycopy";
    break;
  case jeandle::JBasicType::Float:
  case jeandle::JBasicType::Int:
    if (Aligned)
      Name = Disjoint ? "StubRoutines_arrayof_jint_disjoint_arraycopy"
                      : "StubRoutines_arrayof_jint_arraycopy";
    else
      Name = Disjoint ? "StubRoutines_jint_disjoint_arraycopy"
                      : "StubRoutines_jint_arraycopy";
    break;
  case jeandle::JBasicType::Double:
  case jeandle::JBasicType::Long:
    if (Aligned)
      Name = Disjoint ? "StubRoutines_arrayof_jlong_disjoint_arraycopy"
                      : "StubRoutines_arrayof_jlong_arraycopy";
    else
      Name = Disjoint ? "StubRoutines_jlong_disjoint_arraycopy"
                      : "StubRoutines_jlong_arraycopy";
    break;
  case jeandle::JBasicType::Object:
    if (Aligned) {
      if (Disjoint)
        Name = DestUninitialized
                   ? "StubRoutines_arrayof_oop_disjoint_arraycopy_uninit"
                   : "StubRoutines_arrayof_oop_disjoint_arraycopy";
      else
        Name = DestUninitialized
                   ? "StubRoutines_arrayof_oop_arraycopy_uninit"
                   : "StubRoutines_arrayof_oop_arraycopy";
    } else {
      if (Disjoint)
        Name = DestUninitialized
                   ? "StubRoutines_oop_disjoint_arraycopy_uninit"
                   : "StubRoutines_oop_disjoint_arraycopy";
      else
        Name = DestUninitialized
                   ? "StubRoutines_oop_arraycopy_uninit"
                   : "StubRoutines_oop_arraycopy";
    }
    break;
  case jeandle::JBasicType::Count:
    llvm_unreachable("unsupported arraycopy basic type");
  }

  return M.getFunction(Name);
}

bool generateUncheckedArrayCopy(BasicBlock *&ControlBB,
                                jeandle::JBasicType BasicType,
                                bool DisjointBases, Value *Src, Value *SrcPos,
                                Value *Dest, Value *DestPos, Value *CopyLength,
                                bool DestUninitialized,
                                TargetTransformInfo &TTI) {
  if (ControlBB == nullptr)
    return false;

  Module &M = *ControlBB->getParent()->getParent();
  StringRef StubNameForCall;
  Function *CopyFunc =
      basicTypeToArrayCopy(M, BasicType, SrcPos, DestPos, DisjointBases,
                           StubNameForCall, DestUninitialized);
  if (CopyFunc == nullptr)
    return false;

  IRBuilder<> B(ControlBB);
  Value *SrcStart = Src;
  Value *DestStart = Dest;
  if (SrcPos != nullptr || DestPos != nullptr) {
    SrcStart = arrayElementAddress(B, Src, SrcPos, BasicType);
    DestStart = arrayElementAddress(B, Dest, DestPos, BasicType);
  }

  BasicBlock *PartialExitBB = nullptr;
  const jeandle::VMConstants VMConsts = jeandle::VMConstants::fromModule(M);
  const int MaxInlineBytes =
      static_cast<int>(VMConsts.arrayOperationPartialInlineSize());

  if (MaxInlineBytes > 0 && isSubwordArrayElementType(BasicType)) {
    generatePartialInliningBlock(ControlBB, PartialExitBB, BasicType, SrcStart,
                                 DestStart, CopyLength, MaxInlineBytes, TTI);
  }

  IRBuilder<> StubBuilder(ControlBB);
  FunctionType *StubTy = FunctionType::get(
      StubBuilder.getVoidTy(),
      {SrcStart->getType(), DestStart->getType(), StubBuilder.getInt64Ty()},
      false);
  CallInst *StubCall = makeLeafCall(StubBuilder, M, StubTy, StubNameForCall,
                                    {SrcStart, DestStart, CopyLength});
  assert(StubCall != nullptr && "selected arraycopy stub must be declared");
  (void)StubCall;

  // Connecting remaining edges for exit_block coming from stub_block.
  if (PartialExitBB != nullptr) {
    StubBuilder.CreateBr(PartialExitBB);
    ControlBB = PartialExitBB;
  }

  return true;
}

// This is the Jeandle equivalent of C2 PhaseMacroExpand::generate_arraycopy()
bool generateArrayCopy(CallBase &CI, CallBase *Allocation,
                       BasicBlock *&ControlBB,
                       jeandle::JBasicType BasicElemType, Value *Src,
                       Value *SrcPos, Value *Dest, Value *DestPos,
                       Value *CopyLength, bool DisjointBases,
                       bool LengthNeverNegative, BasicBlock *SlowRegion,
                       TargetTransformInfo &TTI) {

  Module *M = CI.getModule();
  LLVMContext &Ctx = CI.getContext();
  Function *F = ControlBB->getParent();
  InvokeInst &Invoke = cast<InvokeInst>(CI);
  BasicBlock *UnwindDest = Invoke.getUnwindDest();
  if (SlowRegion == nullptr)
    SlowRegion = BasicBlock::Create(Ctx, "arraycopy.slow_region", F);

  bool AcopyToUninitialized = false;

  // See if this is the initialization of a freshly allocated array.  This is
  // the Jeandle counterpart of C2's acopy_to_uninitialized decision.  Jeandle
  // still performs the complete new_array zeroing, so this flag only selects
  // the GC barrier stub variant that may omit the destination pre-barrier; it
  // does not yet request C2's head-and-tail-zeroing optimization. Keep the
  // stub selection gated by ReduceBulkZeroing, matching C2's contract when
  // that optimization is disabled.
  const jeandle::VMConstants VMConsts =
      jeandle::VMConstants::fromModule(*M);
  if (VMConsts.reduceBulkZeroing() && Allocation != nullptr) {
    assert((isCopyOf(CI) || isCopyOfRange(CI) || isCloneOopArray(CI)) &&
           "unexpected tightly coupled arraycopy kind");
    assert(Allocation == CI.getArgOperand(2)->stripPointerCasts() &&
           "allocation must produce the arraycopy destination");
    AcopyToUninitialized = true;
  }

  // Results are placed here. LLVM represents C2's result_region with a
  // common successor block and explicit CFG edges.
  BasicBlock *ResultRegion = nullptr;
  BasicBlock *NormalDest = Invoke.getNormalDest();
  ResultRegion = BasicBlock::Create(Ctx, "arraycopy.result", F, NormalDest);
  BranchInst::Create(NormalDest, ResultRegion);
  NormalDest->replacePhiUsesWith(ControlBB, ResultRegion);
  Invoke.setNormalDest(ResultRegion);
  SlowRegion->moveBefore(ResultRegion);

  // The slow control path. A checked-copy failure is merged here with
  // SlowRegion, matching C2's slow_reg2.
  BasicBlock *SlowControl =
      BasicBlock::Create(Ctx, "arraycopy.slow_call", F, ResultRegion);
  IRBuilder<> SlowEntryBuilder(SlowRegion);
  if (SlowRegion->getTerminator() == nullptr)
    SlowEntryBuilder.CreateBr(SlowControl);

  // CI is the terminator of ControlBB. Keep it alive only as the JVM-state
  // carrier for the replacement slow invoke.
  Invoke.removeFromParent();
  UnwindDest->replacePhiUsesWith(ControlBB, SlowControl);

  // Checked control path.
  BasicBlock *CheckedControl = nullptr;
  Value *CheckedValue = nullptr;

  if (BasicElemType == jeandle::JBasicType::Count) {
    CheckedValue = generateGenericArrayCopy(*M, Src, SrcPos, Dest, DestPos,
                                            CopyLength, ControlBB);
    if (CheckedValue == nullptr)
      CheckedValue = ConstantInt::get(Type::getInt32Ty(Ctx), -1);
    CheckedControl = ControlBB;
    ControlBB = nullptr; // matches C2: *ctrl = top() after recording cv.
  }

  // C2 generate_arraycopy() handles length <= 0 before address/stub expansion.
  BasicBlock *NotPosBB =
      generateNonpositiveGuard(ControlBB, CopyLength, LengthNeverNegative);
  if (NotPosBB != nullptr) {
    BasicBlock *LocalCtrl = NotPosBB;

    // (6) length must not be negative.
    if (!LengthNeverNegative)
      generateNegativeGuard(LocalCtrl, CopyLength, SlowRegion, "arraycopy.length");

    // copy_length is 0.
    // TODO: Match C2's dest_needs_zeroing zero-length path: when the tightly
    // coupled destination allocation still needs initialization, clear the
    // complete destination array, emit the secondary Op_Initialize raw-memory
    // barrier, and mark the synthetic InitializeNode complete before entering
    // the zero result path.

    // Present the result of the bypass path.
    IRBuilder<> ZeroBuilder(LocalCtrl);
    ZeroBuilder.CreateBr(ResultRegion);
  }

  // TODO: Match C2's dest_needs_zeroing path for tightly-coupled array
  // allocations: clear the uncopied destination head, test and clear the tail,
  // try generate_block_arraycopy() with 64-bit elements when there is no tail,
  // and merge the resulting control and memory states. Jeandle does not yet
  // model AllocateArrayNode/InitializeNode or the explicit MergeMem state
  // needed to implement this path.

  jeandle::JBasicType CopyType = BasicElemType;
  if (ControlBB != nullptr && CopyType == jeandle::JBasicType::Object) {
    // If src and dest have compatible element types, we can copy bits.
    // Types S[] and D[] are compatible if D is a supertype of S.
    // Otherwise use checkcast_arraycopy, which backs off to slow_arraycopy on
    // the first per-oop check that fails.
    const bool SkipSubtypeCheck =
        isArrayCopyValidated(CI) || isCopyOfValidated(CI) ||
        isCopyOfRangeValidated(CI) || isCloneOopArray(CI);
    if (!SkipSubtypeCheck) {
      IRBuilder<> B(ControlBB);
      Value *SrcKlass = CI.getArgOperand(5);
      Value *DestKlass = CI.getArgOperand(6);

      assert(SrcKlass != nullptr && DestKlass != nullptr &&
             "should have klasses");

      // Test S[] against D[], not S against D, because the secondary supertype
      // cache is generally less busy for the array klass.
      BasicBlock *NotSubtypeCtrl =
          genSubtypeCheck(B, *M, ControlBB, SrcKlass, DestKlass);
      IRBuilder<> CheckcastBuilder(NotSubtypeCtrl);
      Function *LoadArrayElementKlass =
          M->getFunction("jeandle.load_array_element_klass");
      assert(LoadArrayElementKlass != nullptr && "invalid JavaOp");
      CallInst *DestElemKlass =
          CheckcastBuilder.CreateCall(LoadArrayElementKlass, {DestKlass});
      DestElemKlass->setCallingConv(CallingConv::Hotspot_JIT);
      BasicBlock *CheckcastControl = CheckcastBuilder.GetInsertBlock();
      CheckedValue = generateCheckcastArrayCopy(
          CheckcastControl, DestElemKlass, Src, SrcPos, Dest, DestPos,
          CopyLength, AcopyToUninitialized);
      if (CheckedValue == nullptr)
        CheckedValue = ConstantInt::get(Type::getInt32Ty(Ctx), -1);
      CheckedControl = CheckcastControl;
    }

    // TODO: Model BarrierSetC2::array_copy_requires_gc_barriers(). Jeandle does
    // not yet track the allocation/barrier facts needed to rewrite object
    // copies to primitive copies, so keep them on oop-aware paths.
  }

  if (ControlBB != nullptr) {
    // LLVM memory state is represented by load/store/call memory effects rather
    // than an explicit C2 MergeMemNode clone.
    const bool FastPathGenerated = generateUncheckedArrayCopy(
        ControlBB, BasicElemType, DisjointBases, Src, SrcPos, Dest, DestPos,
        CopyLength, AcopyToUninitialized, TTI);

    // C2 records this edge in result_region. LLVM needs an explicit branch.
    if (FastPathGenerated && ControlBB != nullptr) {
      IRBuilder<> FastDoneBuilder(ControlBB);
      FastDoneBuilder.CreateBr(ResultRegion);
      ControlBB = nullptr;
    }
  }

  // Add checked-copy completion and partial-failure paths to the fixed slow
  // endpoint created above.
  if (CheckedControl != nullptr) {
    BasicBlock *ChecksDone =
        BasicBlock::Create(Ctx, "arraycopy.checkcast.done", F, ResultRegion);
    BasicBlock *CheckedFailure =
        BasicBlock::Create(Ctx, "arraycopy.checkcast.failure", F, ChecksDone);
    if (Instruction *Term = CheckedControl->getTerminator())
      Term->eraseFromParent();

    IRBuilder<> CheckedBuilder(CheckedControl);
    Value *Ok = CheckedBuilder.CreateICmpEQ(
        CheckedValue, CheckedBuilder.getInt32(0), "arraycopy.checkcast.ok");
    BranchInst *CheckedGuard =
        CheckedBuilder.CreateCondBr(Ok, ChecksDone, CheckedFailure);
    constexpr uint32_t CheckedSuccessWeight =
        static_cast<uint32_t>(PROB_MAX * BranchWeightScale);
    constexpr uint32_t CheckedFailureWeight =
        BranchWeightScale - CheckedSuccessWeight;
    MDBuilder MDB(Ctx);
    CheckedGuard->setMetadata(
        LLVMContext::MD_prof,
        MDB.createBranchWeights(CheckedSuccessWeight, CheckedFailureWeight));

    IRBuilder<> ChecksDoneBuilder(ChecksDone);
    ChecksDoneBuilder.CreateBr(ResultRegion);

    // The offset PHI and its derived arguments belong to the unified slow
    // block.
    IRBuilder<> SlowOffsetBuilder(SlowControl);
    PHINode *SlowOffsetPhi = SlowOffsetBuilder.CreatePHI(
        CopyLength->getType(), 2, "arraycopy.slow.offset");
    SlowOffsetPhi->addIncoming(
      ConstantInt::get(cast<IntegerType>(CopyLength->getType()), 0), SlowRegion);

    IRBuilder<> CheckedFailureBuilder(CheckedFailure);
    // TODO: Model C2's alloc != nullptr path here. C2 restarts from the
    // beginning after zeroing the whole freshly allocated destination.
    // Jeandle does not model that allocation path yet, so continue exactly
    // where the checked copy failed.
    // The return value is 0 or -1^K, where K elements were copied. Continue
    // exactly where the checked copy failed so another thread cannot observe
    // the wrong number of writes to dest.
    Value *Copied = CheckedFailureBuilder.CreateXor(
        CheckedValue, CheckedFailureBuilder.getInt32(-1),
        "arraycopy.checkcast.copied");
    Value *CopiedX = CheckedFailureBuilder.CreateIntCast(
        Copied, CopyLength->getType(), true,
        "arraycopy.checkcast.copied_x");
    SlowOffsetPhi->addIncoming(CopiedX, CheckedFailure);
    CheckedFailureBuilder.CreateBr(SlowControl);

    Value *SrcPosPlus = SlowOffsetBuilder.CreateAdd(SrcPos, SlowOffsetPhi,
                                                    "arraycopy.slow.src_pos");
    Value *DestPosPlus = SlowOffsetBuilder.CreateAdd(DestPos, SlowOffsetPhi,
                                                     "arraycopy.slow.dest_pos");
    Value *LengthMinus = SlowOffsetBuilder.CreateSub(CopyLength, SlowOffsetPhi,
                                                     "arraycopy.slow.length");

    // Tweak the node variables to adjust the code produced below:
    SrcPos = SrcPosPlus;
    DestPos = DestPosPlus;
    CopyLength = LengthMinus;
  }

  // No unchecked fast path was generated; connect the remaining control to the
  // unified slow_region.
  if (ControlBB != nullptr) {
    if (Instruction *FallthroughTerm = ControlBB->getTerminator())
      FallthroughTerm->eraseFromParent();
    IRBuilder<> SlowEdgeBuilder(ControlBB);
    SlowEdgeBuilder.CreateBr(SlowRegion);
  }

  ControlBB = SlowControl;
  if (ControlBB != nullptr) {
    // C2 creates the checked and fast paths first, then merges their slow
    // controls and emits the real slow call. The detached pseudo invoke
    // supplies the JVM state and exception edge until it is replaced.
    IRBuilder<> SlowBuilder(SlowControl);

    // TODO: Model C2s dest_needs_zeroing cleanup before the fixed slow invoke.
    generateSlowArrayCopy(SlowBuilder, *M, CI, Src, SrcPos, Dest, DestPos,
                          CopyLength);
  }

  // C2 places a StoreStore barrier after a freshly allocated clone's payload
  // copy.  The pseudo invoke is replaced by this pass, so make the publication
  // ordering explicit on the common result edge.  Ordinary arraycopy calls do
  // not carry the fresh-allocation proof and must retain their existing path.
  if (isCloneOopArray(CI)) {
    IRBuilder<> ResultFenceBuilder(ResultRegion->getTerminator());
    emitStoreStoreBarrier(ResultFenceBuilder, *M);
  }

  CI.deleteValue();
  ControlBB = ResultRegion;
  return true;
}

// Expand one jeandle.arraycopy pseudo call. This is the Jeandle equivalent of
// C2 PhaseMacroExpand::expand_arraycopy_node(ArrayCopyNode *ac)
bool expandArrayCopyNode(CallBase &CI, const PseudoCallFacts &Facts,
                         TargetTransformInfo &TTI) {
  assert(isArrayCopyPseudoCall(CI) && "should be an arraycopy");

  Value *Src = CI.getArgOperand(0);
  Value *SrcPos = CI.getArgOperand(1);
  Value *Dest = CI.getArgOperand(2);
  Value *DestPos = CI.getArgOperand(3);
  Value *Length = CI.getArgOperand(4);
  LLVMContext &Ctx = CI.getContext();
  BasicBlock *ControlBB = CI.getParent();
  Function *F = ControlBB->getParent();

  if (isCloneBasic(CI)) {
    cloneAtExpansion(CI);
    return true;
  } else if (isCopyOf(CI) || isCopyOfRange(CI) || isCloneOopArray(CI)) {
    CallBase *Allocation = nullptr;
    if (isAllocTightlyCoupled(CI)) {
      Allocation = findTightlyCoupledArrayAllocation(CI);
      assert(Allocation != nullptr && "expect allocation");
    }

    return generateArrayCopy(CI, Allocation, ControlBB,
                             jeandle::JBasicType::Object, Src, SrcPos, Dest, DestPos,
                             Length, /*DisjointBases=*/true,
                             hasNegativeLengthGuard(CI), nullptr, TTI);
  }

  CallBase *Allocation = nullptr;
  if (isAllocTightlyCoupled(CI)) {
    Allocation = findTightlyCoupledArrayAllocation(CI);
    assert(Allocation != nullptr && "expect allocation");
  }

  // Compile time checks.  If any of these checks cannot be verified at compile
  // time, we do not make a fast path for this call.  Instead, we let the call
  // remain as it is.  The checks we choose to mandate at compile time are:
  //
  // (1) src and dest are arrays.
  jeandle::JBasicType SrcElem = Facts.SrcElem;
  jeandle::JBasicType DestElem = Facts.DestElem;

  if (isReferenceCopyType(SrcElem))
    SrcElem = jeandle::JBasicType::Object;
  if (isReferenceCopyType(DestElem))
    DestElem = jeandle::JBasicType::Object;

  if (isArrayCopyValidated(CI) && DestElem != jeandle::JBasicType::Count &&
      SrcElem == jeandle::JBasicType::Count) {
    SrcElem = DestElem;
  }

  if (SrcElem == jeandle::JBasicType::Count ||
      DestElem == jeandle::JBasicType::Count) {
    // TODO: C2 inserts an Op_MemBarCPUOrder before the unknown-type
    // generic-arraycopy path to conservatively order all memory slices. Jeandle
    // currently relies on the opaque generic stub call as the memory clobber;
    // revisit this if arraycopy calls gain narrower memory attributes or
    // Jeandle starts modeling C2-like memory slices here.

    // Call StubRoutines::generic_arraycopy stub.
    return generateArrayCopy(CI, nullptr, ControlBB, jeandle::JBasicType::Count, Src,
                             SrcPos, Dest, DestPos, Length,
                             /*DisjointBases*/ false,
                             hasNegativeLengthGuard(CI), nullptr, TTI);
  }

  assert((!isArrayCopyValidated(CI) || SrcElem == DestElem) &&
         "validated but different basic types");

  // (2) src and dest arrays must have elements of the same BasicType.
  // Figure out the size and type of the elements we will be copying.
  if (SrcElem != DestElem) {
    IRBuilder<> SlowBuilder(&CI);
    generateSlowArrayCopy(SlowBuilder, *CI.getModule(), CI, Src, SrcPos, Dest,
                          DestPos, Length);
    CI.eraseFromParent();
    return true;
  }

  //---------------------------------------------------------------------------
  // We will make a fast path for this call to arraycopy.

  // We have the following tests left to perform:
  //
  // (3) src and dest must not be null.
  // (4) src_offset must not be negative.
  // (5) dest_offset must not be negative.
  // (6) length must not be negative.
  // (7) src_offset + length must not exceed length of src.
  // (8) dest_offset + length must not exceed length of dest.
  // (9) each element of an oop array must be assignable

  BasicBlock *SlowBB = BasicBlock::Create(Ctx, "arraycopy.slow_region", F);

  if (!isArrayCopyValidated(CI)) {
    // (3) operands must not be null.
    // Null checks are done during Jeandle bytecode lowering before the pseudo
    // call is emitted, matching C2s "null checks done library_call.cpp"
    // contract.

    // (4) src_offset must not be negative.
    generateNegativeGuard(ControlBB, SrcPos, SlowBB,
                          "arraycopy.unvalidated.src_pos", &CI);

    // (5) dest_offset must not be negative.
    generateNegativeGuard(ControlBB, DestPos, SlowBB,
                          "arraycopy.unvalidated.dest_pos", &CI);

    // (6) length must not be negative (handled by generateArrayCopy()).

    // (7) src_offset + length must not exceed length of src.
    // Match C2 macro expansion:
    //   Node* alen = ac->in(ArrayCopyNode::SrcLen);
    Value *SrcLength = CI.getArgOperand(7);
    assert(SrcLength != nullptr && "need src len");
    generateLimitGuard(ControlBB, SrcPos, Length, SrcLength, SlowBB,
                       "arraycopy.unvalidated.src", &CI);

    // (8) dest_offset + length must not exceed length of dest.
    // Match C2 macro expansion:
    //   Node* alen = ac->in(ArrayCopyNode::DestLen);
    Value *DestLength = CI.getArgOperand(8);
    assert(DestLength != nullptr && "need dest len");
    generateLimitGuard(ControlBB, DestPos, Length, DestLength, SlowBB,
                       "arraycopy.unvalidated.dest", &CI);

    // (9) each element of an oop array must be assignable.
    // The generateArrayCopy subroutine checks this.
  }

  return generateArrayCopy(CI, Allocation, ControlBB, DestElem, Src, SrcPos, Dest, DestPos,
                           Length, false, hasNegativeLengthGuard(CI), SlowBB,
                           TTI);
}
} // namespace

PreservedAnalyses ArrayCopySpecialization::run(Function &F,
                                               FunctionAnalysisManager &FAM) {
  if (!jeandle::isRootJavaMethodFunction(F))
    return PreservedAnalyses::all();

  DominatorTree &DT = FAM.getResult<DominatorTreeAnalysis>(F);
  LazyValueInfo &LVI = FAM.getResult<LazyValueAnalysis>(F);
  LVINullEdgeOracle IsNullEdge{LVI};

  // Freeze every dominance-dependent fact before rewriting any pseudo call.
  // CFG expansion invalidates DT and LVI, but the element types and clone
  // callback result remain valid for each original call site.
  SmallVector<PseudoCallFacts, 8> Worklist;
  for (Instruction &I : instructions(F))
    if (auto *CB = dyn_cast<CallBase>(&I))
      if (isArrayCopyPseudoCall(*CB))
        Worklist.push_back(analyzePseudoCall(*CB, DT, IsNullEdge));

  TargetTransformInfo &TTI = FAM.getResult<TargetIRAnalysis>(F);
  bool Changed = false;
  for (PseudoCallFacts &Facts : Worklist) {
    CallBase *CB = Facts.CB;
    if (CB->getParent() == nullptr)
      continue;

    bool CallChanged = false;
    if (arrayCopyIdeal(*CB, Facts))
      CallChanged = true;
    else
      CallChanged |= expandArrayCopyNode(*CB, Facts, TTI);

    Changed |= CallChanged;
  }

  return Changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
}
