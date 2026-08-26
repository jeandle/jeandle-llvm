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

#include <cassert>

using namespace llvm;

namespace {

#define PROB_MIN (1e-6f)
#define PROB_MAX (1.0f - 1e-6f)

constexpr uint32_t BranchWeightScale = 1000000;

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

bool isValidatedArrayCopy(const CallBase &CB) {
  return isArrayCopy(CB) &&
         CB.hasFnAttr(jeandle::Attribute::ValidatedArrayCopy);
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

int getLengthIfConstant(CallBase &CI) {
  auto *Length = dyn_cast<ConstantInt>(CI.getArgOperand(4));
  if (Length == nullptr)
    return -1;

  return static_cast<int>(Length->getSExtValue());
}

// Jeandle counterpart of C2 ArrayCopyNode::get_count().
int getCount(CallBase &CI) {
  if (isCloneBasic(CI)) {
    // TODO: Match C2's clone count calculation for instance and array clones.
    return -1;
  }

  return getLengthIfConstant(CI);
}

jeandle::JBasicType getArrayElementBasicType(uintptr_t Klass) {
  return jeandle::elementTypeForArrayKlass(Klass);
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
  assert(Idx->getType()->isIntegerTy(32) &&
         "array index must have Java int type");

  Module &M = *B.GetInsertBlock()->getModule();
  const int ElementBytes = arrayElementSizeInBytes(M, ElemType);
  assert(ElementBytes > 0 &&
         isPowerOf2_32(static_cast<uint32_t>(ElementBytes)) &&
         "array element size must be a positive power of two");
  const unsigned Shift =
      static_cast<unsigned>(Log2_32(static_cast<uint32_t>(ElementBytes)));
  const int Header = arrayBaseOffsetInBytes(M, ElemType);

  Value *Base = B.CreateGEP(B.getInt8Ty(), Ary, B.getInt64(Header),
                            "arraycopy.element_base");
  Value *Index = B.CreateSExt(Idx, B.getInt64Ty(), "arraycopy.index_x");
  Value *Scale =
      B.CreateShl(Index, B.getInt64(Shift), "arraycopy.element_scale");
  return B.CreateGEP(B.getInt8Ty(), Base, Scale, "arraycopy.element_address");
}

// Jeandle counterpart of C2 ArrayCopyNode::prepare_array_copy.
bool prepareArrayCopy(CallBase &CI, DominatorTree &DT, IRBuilder<> &B,
                      Value *&AdrSrc, Value *&AdrDest,
                      jeandle::JBasicType &CopyType, bool &DisjointBases) {
  AdrSrc = nullptr;
  AdrDest = nullptr;
  CopyType = jeandle::JBasicType::Count;
  DisjointBases = false;

  Value *BaseSrc = CI.getArgOperand(0);
  Value *SrcOffset = CI.getArgOperand(1);
  const jeandle::JavaType SrcType = jeandle::getJavaType(BaseSrc, &DT, &CI);
  jeandle::JBasicType SrcElem = getArrayElementBasicType(SrcType.Klass);
  Value *BaseDest = CI.getArgOperand(2);
  Value *DestOffset = CI.getArgOperand(3);

  if (isArrayCopy(CI)) {
    const jeandle::JavaType DestType = jeandle::getJavaType(BaseDest, &DT, &CI);
    jeandle::JBasicType DestElem = getArrayElementBasicType(DestType.Klass);

    // TODO: Match C2 is_alloc_tightly_coupled(). Jeandle does not carry that
    // allocation relationship on the pseudo call yet.
    DisjointBases = false;

    if (SrcElem == jeandle::JBasicType::Count ||
        DestElem == jeandle::JBasicType::Count) {
      // We don't know if arguments are arrays
      return false;
    }

    if (SrcElem != DestElem) {
      // We don't know if arguments are arrays of the same type
      return false;
    }

    // TODO: Match the remainder of C2 prepare_array_copy(): query BarrierSetC2
    // before admitting object-array load/store expansion, retain the source
    // element value_type for typed oop accesses, and model conv_I2X_index()
    // TOP/out-of-range handling.
    if (!isPrimitiveArrayElementType(DestElem))
      return false;

    CopyType = DestElem;
    AdrSrc = arrayElementAddress(B, BaseSrc, SrcOffset, CopyType);
    AdrDest = arrayElementAddress(B, BaseDest, DestOffset, CopyType);
  } else {
    assert(isCloneBasic(CI) && "unexpected arraycopy kind");
    // TODO: Match C2's clone branch in prepare_array_copy().
    return false;
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
  Type *AccessType = arrayElementStorageType(B.getContext(), CopyType);
  assert(AccessType != nullptr && "unsupported arraycopy load/store type");

  if (Count > 0) {
    LoadInst *LoadedValue = B.CreateLoad(AccessType, AdrSrc, "arraycopy.load");
    LoadedValue->setAtomic(AtomicOrdering::Unordered);
    StoreInst *StoredValue = B.CreateStore(LoadedValue, AdrDest);
    StoredValue->setAtomic(AtomicOrdering::Unordered);

    for (int I = 1; I < Count; ++I) {
      Value *NextSrc = B.CreateInBoundsGEP(AccessType, AdrSrc, B.getInt64(I),
                                           "arraycopy.forward.src");
      Value *NextDest = B.CreateInBoundsGEP(AccessType, AdrDest, B.getInt64(I),
                                            "arraycopy.forward.dest");
      LoadedValue = B.CreateLoad(AccessType, NextSrc, "arraycopy.load");
      LoadedValue->setAtomic(AtomicOrdering::Unordered);
      StoredValue = B.CreateStore(LoadedValue, NextDest);
      StoredValue->setAtomic(AtomicOrdering::Unordered);
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
  Type *AccessType = arrayElementStorageType(B.getContext(), CopyType);
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
    LoadInst *LoadedValue =
        B.CreateLoad(AccessType, SrcAddress, "arraycopy.load");
    LoadedValue->setAtomic(AtomicOrdering::Unordered);
    StoreInst *StoredValue = B.CreateStore(LoadedValue, DestAddress);
    StoredValue->setAtomic(AtomicOrdering::Unordered);
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

// Jeandle equivalent of C2 ArrayCopyNode::Ideal().
bool arrayCopyIdeal(CallBase &CI, DominatorTree &DT) {
  assert(isArrayCopyPseudoCall(CI) && "should be an arraycopy");

  // See if it's a small array copy and we can inline it as
  // loads/stores
  // Here we can only do:
  // - arraycopy if all arguments were validated before and we don't
  // need card marking
  // - clone for which we don't need to do card marking
  if (!isCloneBasic(CI) && !isValidatedArrayCopy(CI))
    return false;

  int Count = getCount(CI);
  Module *M = CI.getModule();
  const jeandle::VMConstants VMConsts = jeandle::VMConstants::fromModule(*M);
  const int MaxElem = static_cast<int>(VMConsts.arrayCopyLoadStoreMaxElem());
  if (Count < 0 || Count > MaxElem)
    return false;

  // TODO: C2 tries try_clone_instance() here. Jeandle still routes instance
  // clones to clone_at_expansion().

  IRBuilder<> B(&CI);
  Value *AdrSrc = nullptr;
  Value *AdrDest = nullptr;
  jeandle::JBasicType CopyType = jeandle::JBasicType::Count;
  bool DisjointBases = false;
  if (!prepareArrayCopy(CI, DT, B, AdrSrc, AdrDest, CopyType, DisjointBases)) {
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
  CallInst *Call = B.CreateCall(Callee, Params, Name);
  Call->setCallingConv(CallingConv::C);
  Call->addFnAttr(Attribute::NoUnwind);
  Call->addFnAttr(Attribute::get(B.getContext(), "gc-leaf-function"));
  // TODO: Add precise LLVM memory effects or AA metadata if alias-analysis
  // evidence shows that arraycopy dependencies block optimization. Do not
  // infer noalias from the element BasicType: source and destination may
  // overlap, and oop copies also interact with GC barriers.
  return Call;
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

void generateLimitGuard(BasicBlock *&ControlBB, Value *Offset, Value *Length,
                        Value *ArrayLength, BasicBlock *SlowBB,
                        StringRef Prefix, CallBase *BeforeCall = nullptr) {
  IRBuilder<> B(ControlBB);
  if (BeforeCall != nullptr)
    B.SetInsertPoint(BeforeCall);

  auto *ConstantOffset = dyn_cast<ConstantInt>(Offset);
  const bool ZeroOffset = ConstantOffset != nullptr && ConstantOffset->isZero();
  if (ZeroOffset && Length == ArrayLength)
    return;

  Type *I64 = B.getInt64Ty();
  Value *Last = B.CreateSExt(Length, I64, Twine(Prefix) + ".last64");
  if (!ZeroOffset) {
    Value *Offset64 = B.CreateSExt(Offset, I64, Twine(Prefix) + ".offset64");
    Last = B.CreateAdd(Last, Offset64, Twine(Prefix) + ".last");
  }
  Value *ArrayLength64 =
      B.CreateSExt(ArrayLength, I64, Twine(Prefix) + ".array_length64");
  Value *ExceedsLimit =
      B.CreateICmpULT(ArrayLength64, Last, Twine(Prefix) + ".exceeds_limit");
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

  SmallVector<Value *, 6> Args = {Src, SrcPos, Dest, DestPos, Length, Thread};
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
                                     Value *CopyLengthX,
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

  // TODO: Model StubRoutines::checkcast_arraycopy(dest_uninitialized). Jeandle
  // currently exposes only the normal StubRoutines_checkcast_arraycopy symbol.
  (void)DestUninitialized;

  Function *CopyFunc = M.getFunction("StubRoutines_checkcast_arraycopy");
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
      B, M, StubTy, "StubRoutines_checkcast_arraycopy",
      {SrcStart, DestStart, CopyLengthX, CheckOffset, DestElemKlass},
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
    if (DestUninitialized)
      return nullptr;
    if (Aligned)
      Name = Disjoint ? "StubRoutines_arrayof_oop_disjoint_arraycopy"
                      : "StubRoutines_arrayof_oop_arraycopy";
    else
      Name = Disjoint ? "StubRoutines_oop_disjoint_arraycopy"
                      : "StubRoutines_oop_arraycopy";
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

  Type *I64 = B.getInt64Ty();
  assert(CopyLength->getType()->isIntegerTy(32) &&
         "arraycopy copy_length must be an int before ConvI2X");
  Value *CopyLengthX = B.CreateSExt(CopyLength, I64, "arraycopy.length_x");

  BasicBlock *PartialExitBB = nullptr;
  const jeandle::VMConstants VMConsts = jeandle::VMConstants::fromModule(M);
  const int MaxInlineBytes =
      static_cast<int>(VMConsts.arrayOperationPartialInlineSize());

  if (MaxInlineBytes > 0 && isSubwordArrayElementType(BasicType)) {
    generatePartialInliningBlock(ControlBB, PartialExitBB, BasicType, SrcStart,
                                 DestStart, CopyLengthX, MaxInlineBytes, TTI);
  }

  IRBuilder<> StubBuilder(ControlBB);
  FunctionType *StubTy = FunctionType::get(
      StubBuilder.getVoidTy(),
      {SrcStart->getType(), DestStart->getType(), StubBuilder.getInt64Ty()},
      false);
  CallInst *StubCall = makeLeafCall(StubBuilder, M, StubTy, StubNameForCall,
                                    {SrcStart, DestStart, CopyLengthX});
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
bool generateArrayCopy(CallBase &CI, BasicBlock *&ControlBB,
                       jeandle::JBasicType BasicElemType, Value *Src,
                       Value *SrcPos, Value *Dest, Value *DestPos,
                       Value *Length, bool DisjointBases,
                       bool LengthNeverNegative, BasicBlock *SlowRegion,
                       TargetTransformInfo &TTI) {

  Module *M = CI.getModule();
  LLVMContext &Ctx = CI.getContext();
  Function *F = ControlBB->getParent();
  InvokeInst &Invoke = cast<InvokeInst>(CI);
  BasicBlock *UnwindDest = Invoke.getUnwindDest();
  if (SlowRegion == nullptr)
    SlowRegion = BasicBlock::Create(Ctx, "arraycopy.slow_region", F);

  bool AcopyToUninitialized = false; // now it's always false

  // TODO: Model C2s tightly-coupled allocation path here, before deriving
  // arraycopy addresses or selecting stubs: ReduceBulkZeroing,
  // InitializeNode::set_complete_with_arraycopy(), acopy_to_uninitialized, and
  // head/tail zeroing of the non-copied destination ranges.

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
                                            Length, ControlBB);
    if (CheckedValue == nullptr)
      CheckedValue = ConstantInt::get(Type::getInt32Ty(Ctx), -1);
    CheckedControl = ControlBB;
    ControlBB = nullptr; // matches C2: *ctrl = top() after recording cv.
  }

  // C2 generate_arraycopy() handles length <= 0 before address/stub expansion.
  BasicBlock *NotPosBB =
      generateNonpositiveGuard(ControlBB, Length, LengthNeverNegative);
  if (NotPosBB != nullptr) {
    BasicBlock *LocalCtrl = NotPosBB;

    // (6) length must not be negative.
    if (!LengthNeverNegative)
      generateNegativeGuard(LocalCtrl, Length, SlowRegion, "arraycopy.length");

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
        isValidatedArrayCopy(CI) || isCloneOopArray(CI);
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
      Type *I64 = CheckcastBuilder.getInt64Ty();
      assert(Length->getType()->isIntegerTy(32) &&
             "arraycopy copy_length must be an int before ConvI2X");
      Value *CopyLengthX = CheckcastBuilder.CreateSExt(
          Length, I64, "arraycopy.checkcast.length_x");
      BasicBlock *CheckcastControl = CheckcastBuilder.GetInsertBlock();
      CheckedValue = generateCheckcastArrayCopy(
          CheckcastControl, DestElemKlass, Src, SrcPos, Dest, DestPos,
          CopyLengthX, AcopyToUninitialized);
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
        Length, AcopyToUninitialized, TTI);

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
        Length->getType(), 2, "arraycopy.slow.offset");
    SlowOffsetPhi->addIncoming(ConstantInt::get(Length->getType(), 0),
                               SlowRegion);

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
    SlowOffsetPhi->addIncoming(Copied, CheckedFailure);
    CheckedFailureBuilder.CreateBr(SlowControl);

    Value *SrcPosPlus = SlowOffsetBuilder.CreateAdd(SrcPos, SlowOffsetPhi,
                                                    "arraycopy.slow.src_pos");
    Value *DestPosPlus = SlowOffsetBuilder.CreateAdd(DestPos, SlowOffsetPhi,
                                                     "arraycopy.slow.dest_pos");
    Value *LengthMinus = SlowOffsetBuilder.CreateSub(Length, SlowOffsetPhi,
                                                     "arraycopy.slow.length");

    // Tweak the node variables to adjust the code produced below:
    SrcPos = SrcPosPlus;
    DestPos = DestPosPlus;
    Length = LengthMinus;
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
                          Length);
  }

  CI.deleteValue();
  ControlBB = ResultRegion;
  return true;
}

// Expand one jeandle.arraycopy pseudo call. This is the Jeandle equivalent of
// C2 PhaseMacroExpand::expand_arraycopy_node(ArrayCopyNode *ac)
bool expandArrayCopyNode(CallBase &CI, DominatorTree &DT,
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
    // TODO: Match C2's clone_at_expansion() path.
    return false;
  } else if (isCloneOopArray(CI)) {
    // TODO: Match C2's CloneOopArray expansion path.
    return false;
  }

  // TODO: Match C2 is_alloc_tightly_coupled() and recover the corresponding
  // AllocateArrayNode with Ideal_array_allocation().

  // Compile time checks.  If any of these checks cannot be verified at compile
  // time, we do not make a fast path for this call.  Instead, we let the call
  // remain as it is.  The checks we choose to mandate at compile time are:
  //
  // (1) src and dest are arrays.
  const jeandle::JavaType SrcType = jeandle::getJavaType(Src, &DT, &CI);
  const jeandle::JavaType DestType = jeandle::getJavaType(Dest, &DT, &CI);

  jeandle::JBasicType SrcElem = getArrayElementBasicType(SrcType.Klass);
  jeandle::JBasicType DestElem = getArrayElementBasicType(DestType.Klass);

  if (isValidatedArrayCopy(CI) && DestElem != jeandle::JBasicType::Count &&
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
    return generateArrayCopy(CI, ControlBB, jeandle::JBasicType::Count, Src,
                             SrcPos, Dest, DestPos, Length,
                             /*DisjointBases*/ false,
                             hasNegativeLengthGuard(CI), nullptr, TTI);
  }

  assert((!isValidatedArrayCopy(CI) || SrcElem == DestElem) &&
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

  if (!isValidatedArrayCopy(CI)) {
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

  return generateArrayCopy(CI, ControlBB, DestElem, Src, SrcPos, Dest, DestPos,
                           Length, false, hasNegativeLengthGuard(CI), SlowBB,
                           TTI);
}
} // namespace

PreservedAnalyses ArrayCopySpecialization::run(Function &F,
                                               FunctionAnalysisManager &FAM) {
  if (!jeandle::isRootJavaMethodFunction(F))
    return PreservedAnalyses::all();

  SmallVector<CallBase *, 8> PseudoCalls;
  for (Instruction &I : instructions(F))
    if (auto *CB = dyn_cast<CallBase>(&I))
      if (isArrayCopyPseudoCall(*CB))
        PseudoCalls.push_back(CB);

  DominatorTree &DT = FAM.getResult<DominatorTreeAnalysis>(F);
  TargetTransformInfo &TTI = FAM.getResult<TargetIRAnalysis>(F);
  bool Changed = false;
  for (CallBase *CB : PseudoCalls) {
    if (CB->getParent() == nullptr)
      continue;

    bool CallChanged = false;
    if (arrayCopyIdeal(*CB, DT))
      CallChanged = true;
    else
      CallChanged |= expandArrayCopyNode(*CB, DT, TTI);

    Changed |= CallChanged;
    if (CallChanged)
      DT.recalculate(F);
  }

  return Changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
}
