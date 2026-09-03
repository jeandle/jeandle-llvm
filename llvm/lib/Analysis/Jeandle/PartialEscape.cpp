//===- PartialEscape.cpp - PEA shared data structure impls ----------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
// Implementation of non-trivial method bodies for the PEA data structures
// declared in llvm/include/llvm/Analysis/Jeandle/PartialEscape.h.

#include "llvm/Analysis/Jeandle/PartialEscape.h"
#include "llvm/Analysis/Jeandle/DeoptPoolBundleLowering.h"

#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/Analysis/Jeandle/PartialEscapeUtils.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/IR/Argument.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/InstrTypes.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Operator.h"
#include "llvm/IR/PatternMatch.h"
#include "llvm/IR/Type.h"
#include "llvm/IR/Value.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/MathExtras.h"
#include "llvm/Support/raw_ostream.h"

#include <algorithm>
#include <limits>

using namespace llvm;
using namespace llvm::jeandle;

// Per-effect dbgs() trace. Effects are published only from
// publishAttemptOutputs, after the analysis attempt has validated, so a
// discarded attempt cannot leak provisional decisions. Off by default; turn
// on with -jeandle-trace-pea.
static llvm::cl::opt<bool> JeandleTracePEA(
    "jeandle-trace-pea", llvm::cl::init(false), llvm::cl::Hidden,
    llvm::cl::desc("PEA: emit a one-line dbgs() trace on every major "
                   "effect emission (EliminateAllocation / Materialize / "
                   "ReplaceCall / ReplaceLoad / EliminateStore / "
                   "CreatePHI)."));

// ===========================================================================
// VirtualObject
// ===========================================================================

std::optional<bool> VirtualObject::FieldDesc::overlaps(int64_t Off,
                                                       uint8_t Size) const {
  return jeandle::pea::checkedRangesOverlap(Offset, ByteSize, Off, Size);
}

// Find the FieldDesc slot for (Offset, Ty), creating it if needed while
// keeping Fields sorted by Offset. Returns the slot's index on success.
// Returns -1 whenever the field cannot be modeled safely — unsupported or
// non-heap-pointer type, unrepresentable byte range, size/reference-ness
// conflict with the existing slot, or overlap with a neighbor; every caller
// treats -1 as "keep everything real" (the access conservatively escapes),
// so this function may refuse anything it cannot model exactly.
int VirtualObject::getOrCreateFieldIndex(int64_t Offset, Type *Ty,
                                         const DataLayout &DL) {
  assert(Ty && "field type must be non-null");
  if (!jeandle::pea::isLegalMaterializationAtomicType(Ty, DL))
    return -1;

  uint8_t ByteSize = 0;
  bool IsReference = false;
  if (Ty->isPointerTy()) {
    // Reference field: ptr addrspace(1). Its byte size is the target's Java
    // heap pointer size (DL.getPointerSize(JavaHeapAddrSpace)) — 8 on the
    // current 64-bit target, but derived from the DataLayout so a 32-bit or
    // compressed-oop heap model stays correct rather than hardcoding 8.
    //
    // Reference fields may use the semantic Java heap pointer (AS1) or the
    // physical narrow-oop pointer (AS3). Keep the descriptor's type so
    // materialization can replay the value at its actual in-memory width.
    unsigned PointerAS = Ty->getPointerAddressSpace();
    if (PointerAS != jeandle::AddrSpace::JavaHeapAddrSpace &&
        PointerAS != jeandle::AddrSpace::NarrowOopAddrSpace)
      return -1;
    uint64_t PointerByteSize = DL.getPointerSize(PointerAS);
    if (PointerByteSize == 0 ||
        PointerByteSize > std::numeric_limits<uint8_t>::max())
      return -1;
    ByteSize = static_cast<uint8_t>(PointerByteSize);
    IsReference = true;
  } else {
    TypeSize Bits = DL.getTypeSizeInBits(Ty);
    if (Bits.isScalable())
      return -1; // runtime-dependent field width — conservative escape
    uint64_t FixedBits = Bits.getFixedValue();
    if (FixedBits == 0)
      return -1; // unknown-size type (e.g. aggregate) — conservative escape
    // FieldDesc intentionally uses a compact byte-size representation. Wider
    // verifier-legal atomic types conservatively stay real.
    if (FixedBits > std::numeric_limits<uint8_t>::max() * 8ULL)
      return -1;
    ByteSize = static_cast<uint8_t>((FixedBits + 7) / 8);
  }

  // This endpoint check is required even for the first field, where there is
  // no neighbor overlap query to validate the endpoint.
  if (!jeandle::pea::isUsableFieldOffset(Offset) ||
      !jeandle::pea::checkedOffsetAdd(Offset, ByteSize))
    return -1;

  // Fields is sorted by Offset. Locate the insertion point for Offset, reuse
  // an exact-match slot, otherwise verify the new slot overlaps neither
  // neighbor before inserting.
  auto It = std::lower_bound(
      Fields.begin(), Fields.end(), Offset,
      [](const FieldDesc &F, int64_t Off) { return F.Offset < Off; });

  // Exact match? Reuse if the existing FieldDesc agrees on size and
  // reference-ness.
  if (It != Fields.end() && It->Offset == Offset) {
    if (It->ByteSize != ByteSize || It->IsReference != IsReference)
      return -1;
    return static_cast<int>(It - Fields.begin());
  }

  // Overlap check against the candidate neighbor on the left.
  if (It != Fields.begin()) {
    auto Prev = std::prev(It);
    std::optional<bool> Overlap = Prev->overlaps(Offset, ByteSize);
    if (!Overlap || *Overlap)
      return -1;
  }
  // Overlap check against the candidate neighbor on the right.
  if (It != Fields.end()) {
    std::optional<bool> Overlap = It->overlaps(Offset, ByteSize);
    if (!Overlap || *Overlap)
      return -1;
  }

  FieldDesc New{Offset, Ty, ByteSize, IsReference};
  auto NewIt = Fields.insert(It, New);
  return static_cast<int>(NewIt - Fields.begin());
}
const VirtualObject::FieldDesc *VirtualObject::findField(int64_t Offset) const {
  auto It = std::lower_bound(
      Fields.begin(), Fields.end(), Offset,
      [](const FieldDesc &F, int64_t Off) { return F.Offset < Off; });
  if (It == Fields.end() || It->Offset != Offset)
    return nullptr;
  return &*It;
}

// Strip identity-preserving wrappers (freeze, bitcast, zext, sext) from an
// index Value. Used by matchArrayElementGEP to canonicalize the index so
// callers can pattern-match a ConstantInt or a Value identity.
static Value *peelIndexWrappers(Value *V) {
  for (unsigned Depth = 0; Depth < 8; ++Depth) {
    if (!V)
      return V;
    if (auto *FI = dyn_cast<FreezeInst>(V)) {
      V = FI->getOperand(0);
      continue;
    }
    if (auto *BC = dyn_cast<BitCastOperator>(V)) {
      // BitCast on an integer (the index slot) is identity-preserving.
      V = BC->getOperand(0);
      continue;
    }
    if (auto *ZI = dyn_cast<ZExtInst>(V)) {
      V = ZI->getOperand(0);
      continue;
    }
    if (auto *SI = dyn_cast<SExtInst>(V)) {
      V = SI->getOperand(0);
      continue;
    }
    // Handle the ConstantExpr forms in case they appear here.
    if (auto *CE = dyn_cast<ConstantExpr>(V)) {
      if (CE->getOpcode() == Instruction::ZExt ||
          CE->getOpcode() == Instruction::SExt ||
          CE->getOpcode() == Instruction::BitCast) {
        V = CE->getOperand(0);
        continue;
      }
    }
    break;
  }
  return V;
}

// Match the symbolic byte-offset pattern emitted by the abstract
// interpreter for indexed accesses on an i8-typed GEP: byteOff equals
// `ArrayBaseOffset + idx * scale`, where the scaling is expressed as a
// shift by log2(scale) or a multiply by scale. Returns the (peeled) index
// Value on success, or nullptr on no match.
static Value *matchAddBasePlusScaledIndex(Value *ByteOff,
                                          int64_t ExpectedBaseOffset,
                                          uint64_t Scale) {
  using namespace llvm::PatternMatch;
  if (!ByteOff || !ByteOff->getType()->isIntegerTy())
    return nullptr;
  if (Scale == 0)
    return nullptr;

  // Bind the constant base and the scaled-index operand of an `add C, X`
  // pair, accepting either operand order.
  Value *ScaledIdx = nullptr;
  ConstantInt *BaseCI = nullptr;
  if (match(ByteOff, m_Add(m_ConstantInt(BaseCI), m_Value(ScaledIdx)))) {
  } else if (match(ByteOff, m_Add(m_Value(ScaledIdx), m_ConstantInt(BaseCI)))) {
  } else {
    return nullptr;
  }
  std::optional<int64_t> Base =
      BaseCI ? BaseCI->getValue().trySExtValue() : std::nullopt;
  if (!Base || *Base != ExpectedBaseOffset)
    return nullptr;

  // Now ScaledIdx must equal idx * Scale (or idx if Scale == 1).
  if (Scale == 1)
    return peelIndexWrappers(ScaledIdx);

  Value *Idx = nullptr;
  if (isPowerOf2_64(Scale)) {
    unsigned LogScale = Log2_64(Scale);
    ConstantInt *ShAmt = nullptr;
    std::optional<uint64_t> Shift;
    if (match(ScaledIdx, m_Shl(m_Value(Idx), m_ConstantInt(ShAmt))) && ShAmt &&
        (Shift = ShAmt->getValue().tryZExtValue()) && *Shift == LogScale)
      return peelIndexWrappers(Idx);
  }
  ConstantInt *MulCI = nullptr;
  if (match(ScaledIdx, m_Mul(m_Value(Idx), m_ConstantInt(MulCI))) && MulCI) {
    std::optional<int64_t> Mul = MulCI->getValue().trySExtValue();
    if (Mul && *Mul >= 0 && static_cast<uint64_t>(*Mul) == Scale)
      return peelIndexWrappers(Idx);
  }
  if (match(ScaledIdx, m_Mul(m_ConstantInt(MulCI), m_Value(Idx))) && MulCI) {
    std::optional<int64_t> Mul = MulCI->getValue().trySExtValue();
    if (Mul && *Mul >= 0 && static_cast<uint64_t>(*Mul) == Scale)
      return peelIndexWrappers(Idx);
  }
  return nullptr;
}

std::optional<VirtualObject::ArrayElementGEPMatch>
VirtualObject::matchArrayElementGEP(GetElementPtrInst *GEP,
                                    const DataLayout &DL) const {
  if (!GEP)
    return std::nullopt;
  if (Kind != Array || !ArrayElementType || ArrayIndexScale == 0)
    return std::nullopt;

  auto *GEPOp = cast<GEPOperator>(GEP);
  const unsigned AS = GEPOp->getPointerAddressSpace();
  const unsigned IndexBits = DL.getIndexSizeInBits(AS);

  // Pattern A: typed GEP with sourceElementType == ArrayElementType. The
  // typed GEP's pointer operand must reach the alloc base with a constant
  // accumulated byte offset equal to ArrayBaseOffset (Jeandle emits this
  // as a preceding i8 + base-offset GEP). The LLVM typed stride must exactly
  // match the VM scale; otherwise converting the recovered index back with
  // ArrayIndexScale would change the original byte address.
  TypeSize TypedStride = DL.getTypeAllocSize(ArrayElementType);
  bool ExactTypedStride = !TypedStride.isScalable() &&
                          TypedStride.getFixedValue() == ArrayIndexScale;
  if (ExactTypedStride && GEPOp->getSourceElementType() == ArrayElementType &&
      GEPOp->getNumIndices() == 1) {
    int64_t BaseOff = 0;
    bool NonConst = false;
    (void)jeandle::pea::stripPointerCastsAndOffsets(GEPOp->getPointerOperand(),
                                                    DL, &BaseOff, &NonConst);
    if (!NonConst && BaseOff == static_cast<int64_t>(ArrayBaseOffset))
      return ArrayElementGEPMatch{peelIndexWrappers(GEPOp->getOperand(1)),
                                  ArrayElementType};
  }

  // Pattern B: i8 GEP with a single byte-offset index. The byte offset may
  // be (a) a constant equal to ArrayBaseOffset + cidx * Scale, or (b) an
  // `add ArrayBaseOffset, (shl|mul) idx, Scale`. Pattern (a) is handled
  // naturally by resolveFieldOffset (constant byte offset), so the
  // matcher's main job here is pattern (b) for symbolic indices, but we
  // still recognise (a) and surface a ConstantInt-wrapped element index.
  if (GEPOp->getSourceElementType()->isIntegerTy(8) &&
      GEPOp->getNumIndices() == 1) {
    int64_t BaseOff = 0;
    bool NonConst = false;
    (void)jeandle::pea::stripPointerCastsAndOffsets(GEPOp->getPointerOperand(),
                                                    DL, &BaseOff, &NonConst);
    if (NonConst || BaseOff != 0)
      return std::nullopt;

    Value *ByteOff = GEPOp->getOperand(1);
    if (auto *CI = dyn_cast<ConstantInt>(ByteOff)) {
      // Constant byte offset. Recover the element index if (off - base) is
      // a multiple of Scale and lies in [0, ArrayLength).
      std::optional<int64_t> Off =
          CI->getValue().sextOrTrunc(IndexBits).trySExtValue();
      std::optional<int64_t> Adj =
          Off ? jeandle::pea::checkedOffsetSub(
                    *Off, static_cast<int64_t>(ArrayBaseOffset))
              : std::nullopt;
      if (!Adj || *Adj < 0 ||
          (*Adj % static_cast<int64_t>(ArrayIndexScale)) != 0)
        return std::nullopt;
      int64_t Cidx = *Adj / static_cast<int64_t>(ArrayIndexScale);
      if (Cidx < 0 || static_cast<uint64_t>(Cidx) >= ArrayLength)
        return std::nullopt;
      Constant *CIdx = ConstantInt::get(CI->getType(), Cidx, /*isSigned=*/true);
      return ArrayElementGEPMatch{CIdx, ArrayElementType};
    }

    if (Value *Idx = matchAddBasePlusScaledIndex(
            ByteOff, static_cast<int64_t>(ArrayBaseOffset), ArrayIndexScale))
      return ArrayElementGEPMatch{Idx, ArrayElementType};
  }

  return std::nullopt;
}

void VirtualObject::copyStructuralFieldsFrom(const VirtualObject &O) {
  Klass = O.Klass;
  SizeInBytes = O.SizeInBytes;
  ArrayLength = O.ArrayLength;
  ArrayElementType = O.ArrayElementType;
  ArrayIndexScale = O.ArrayIndexScale;
  ArrayBaseOffset = O.ArrayBaseOffset;
  Fields = O.Fields;
}

VirtualObject::VirtualObject(ObjectID id, ClassKind k, CallBase *alloc)
    : ID(id), Kind(k), AllocationCall(alloc) {}

std::unique_ptr<VirtualObject> VirtualObject::duplicate() const {
  // The clone is detached: ID is set to InvalidObjectID and the caller is
  // expected to register it via PEAResult::createVirtualObject to obtain a
  // fresh ID.
  auto Clone = std::make_unique<VirtualObject>(
      InvalidObjectID, Kind, cast_or_null<CallBase>((Value *)AllocationCall));
  Clone->copyStructuralFieldsFrom(*this);
  // Synthetic-state fields are NOT copied — duplicate() is shared by the
  // generic VirtualObject clone path AND the Case C synthesis path; the
  // latter sets IsSynthetic/SyntheticSourceIDs/SyntheticPhi explicitly after
  // calling duplicate.
  Clone->IsSynthetic = false;
  Clone->SyntheticPhi = nullptr;
  return Clone;
}

// ===========================================================================
// FieldValue
// ===========================================================================

FieldValue FieldValue::scalar(Value *V) {
  assert(V && "scalar value must be non-null");
  FieldValue F;
  F.T = Scalar;
  F.V = V;
  F.DeclaredType = V->getType();
  return F;
}

FieldValue FieldValue::virtualRef(ObjectID ID, Type *RefTy) {
  assert(ID != InvalidObjectID);
  assert(RefTy && RefTy->isPointerTy() &&
         RefTy->getPointerAddressSpace() ==
             jeandle::AddrSpace::JavaHeapAddrSpace &&
         "virtualRef DeclaredType must be ptr addrspace(1)");
  FieldValue F;
  F.T = VirtualRef;
  F.Ref = ID;
  F.DeclaredType = RefTy;
  return F;
}

FieldValue FieldValue::materializedRef(Value *Ptr) {
  assert(Ptr && Ptr->getType()->isPointerTy());
  FieldValue F;
  F.T = MaterializedRef;
  F.V = Ptr;
  F.DeclaredType = Ptr->getType();
  return F;
}

Constant *FieldValue::defaultFor(Type *FieldType) {
  assert(FieldType);
  if (FieldType->isPointerTy()) {
    assert((FieldType->getPointerAddressSpace() ==
                jeandle::AddrSpace::JavaHeapAddrSpace ||
            FieldType->getPointerAddressSpace() ==
                jeandle::AddrSpace::NarrowOopAddrSpace) &&
           "reference default must be a Java oop pointer");
    return ConstantPointerNull::get(cast<PointerType>(FieldType));
  }
  return Constant::getNullValue(FieldType);
}

bool FieldValue::shallowEquals(const FieldValue &O) const {
  if (T != O.T)
    return false;
  switch (T) {
  case Unknown:
    return true;
  case Scalar:
  case MaterializedRef:
    return (Value *)V == (Value *)O.V;
  case VirtualRef:
    return Ref == O.Ref;
  }
  return false;
}

// ===========================================================================
// PEABlockState
// ===========================================================================

// copy/move/assign/dtor are implicitly generated (rule of zero): they just
// copy/move/destroy the ObjectStates shared_ptr, which keeps use_count exact.
// No manual refcount is maintained.

PEABlockState::PEABlockState()
    : ObjectStates(
          std::make_shared<SmallVector<std::optional<ObjectState>, 8>>()) {}

SmallVector<std::optional<ObjectState>, 8> *
PEABlockState::getArrayForModification() {
  // Array-level copy-on-write. ObjectStates is a shared_ptr; when this
  // PEABlockState does not uniquely own it (a snapshot or peer shares it),
  // deep-copy the vector before mutating. ObjectState is stored by value in
  // the vector, so the deep copy already clones every slot — no per-slot
  // sharing annotation is needed.
  if (!ObjectStates) {
    // Defensive: a default-constructed PEABlockState always allocates an empty
    // vector, but a moved-from instance can leave us null.
    ObjectStates =
        std::make_shared<SmallVector<std::optional<ObjectState>, 8>>();
  } else if (ObjectStates.use_count() > 1) {
    // Copy-on-write detach. Unreachable by construction: processBlock() resets
    // CurrentState to a fresh PEABlockState at every block header, so the loop
    // snapshot (the sole producer of shared state) never leaves CurrentState
    // shared at a mutation point. The detach guard keeps snapshots sound.
    ObjectStates = std::make_shared<SmallVector<std::optional<ObjectState>, 8>>(
        *ObjectStates);
    assert(ObjectStates.use_count() == 1 &&
           "COW detach did not yield sole ownership");
  }
  return ObjectStates.get();
}

void PEABlockState::addObject(ObjectID ID, ObjectState State) {
  assert(ID != InvalidObjectID);
  // Route the write through the helper-returned pointer so we never touch
  // the shared_ptr's raw payload before COW has had a chance to detach us.
  auto *Arr = getArrayForModification();
  if (Arr->size() < ID + 1)
    Arr->resize(ID + 1);
  (*Arr)[ID] = std::move(State);
}

bool PEABlockState::hasObjectState(ObjectID ID) const {
  if (!ObjectStates || ID >= ObjectStates->size())
    return false;
  return (*ObjectStates)[ID].has_value();
}

const ObjectState &PEABlockState::getObjectState(ObjectID ID) const {
  assert(hasObjectState(ID));
  return *(*ObjectStates)[ID];
}

const ObjectState *PEABlockState::getObjectStateOptional(ObjectID ID) const {
  if (!ObjectStates || ID >= ObjectStates->size())
    return nullptr;
  const auto &Slot = (*ObjectStates)[ID];
  return Slot ? &*Slot : nullptr;
}

ObjectState &PEABlockState::getObjectStateForModification(ObjectID ID) {
  assert(ID != InvalidObjectID);
  auto *Arr = getArrayForModification();
  assert(ID < Arr->size() && (*Arr)[ID].has_value() &&
         "object not registered in this block state");
  // getArrayForModification already COW-detached the whole vector (deep-copying
  // every slot) if it was shared, so this slot is privately owned.
  return *(*Arr)[ID];
}

// ===========================================================================
// AliasMap
// ===========================================================================

void AliasMap::addVirtualAlias(Value *V, ObjectID ID, bool IsWholeObject) {
  assert(V && ID != InvalidObjectID);
  auto It = VirtualAliases.find(V);
  if (It != VirtualAliases.end()) {
    assert(It->second == ID && "value already aliased to a different object");
  } else {
    VirtualAliases[V] = ID;
  }
  if (IsWholeObject)
    WholeObjectVirtualAliases.insert(V);
  for (User *U : V->users()) {
    if (auto *I = dyn_cast<Instruction>(U))
      HasVirtualInputs.insert(I);
  }
}

void AliasMap::addScalarAlias(Value *V, Value *Replacement) {
  assert(V && Replacement);
  ScalarAliases[V] = Replacement;
}

void AliasMap::resetAlias(Value *V) {
  VirtualAliases.erase(V);
  WholeObjectVirtualAliases.erase(V);
  ScalarAliases.erase(V);
}

std::optional<ObjectID> AliasMap::getVirtualAlias(Value *V) const {
  auto It = VirtualAliases.find(V);
  if (It == VirtualAliases.end())
    return std::nullopt;
  return It->second;
}

Value *AliasMap::getScalarAlias(Value *V) const {
  auto It = ScalarAliases.find(V);
  return It == ScalarAliases.end() ? nullptr : It->second;
}

void AliasMap::clear() {
  VirtualAliases.clear();
  WholeObjectVirtualAliases.clear();
  ScalarAliases.clear();
  HasVirtualInputs.clear();
}

AliasMap AliasMap::snapshot() const { return *this; }

void AliasMap::restore(const AliasMap &S) { *this = S; }

// ===========================================================================
// PEAResult
// ===========================================================================

// Build the final physical lock-replay batches from the surviving
// MaterializeEffects (see the LockReplayBatches field doc in PartialEscape.h
// for the batching rules this implements). Steps: bucket the effects by their
// edge-normalized emit site (InsertBefore); form one batch per lock-carrying
// site and elect its highest-SeqNo effect as the tail emitter; merge each
// site's per-effect locks into MergedLocks, deduplicating identical folded
// enters while recording every logical consumer; sort each batch ascending by
// BytecodeDepth; finally emit the -jeandle-trace-pea LockReplay rows with
// deterministic provenance IDs.
void PEAResult::computeEscapePointLocks() {
  LockReplayBatches.clear();
  LockReplayBatchForSite.clear();

  // SeqNo is analysis-run monotonic, so collecting effects in this order makes
  // batch IDs and first-seen provenance IDs independent of DenseMap iteration.
  SmallVector<jeandle::MaterializeEffect *, 8> Effects;
  for (auto &Kv : BlockEffects)
    for (jeandle::Effect &E : Kv.second) {
      auto *ME = dyn_cast<jeandle::MaterializeEffect>(&E);
      if (ME)
        Effects.push_back(ME);
    }
  llvm::sort(Effects, [](const jeandle::MaterializeEffect *A,
                         const jeandle::MaterializeEffect *B) {
    return A->SeqNo < B->SeqNo;
  });

  DenseMap<const Value *, uint32_t> LogicalEscapeIDs;
  DenseMap<const BasicBlock *, uint32_t> SourceIDs;
  SmallVector<SmallVector<jeandle::MaterializeEffect *, 4>, 4> BatchEffects;
  DenseMap<Instruction *, unsigned> SiteIndex;
  SmallVector<Instruction *, 4> Sites;
  SmallVector<SmallVector<jeandle::MaterializeEffect *, 4>, 4> SiteEffects;
  auto GetLogicalEscapeID = [&](const Value *Key) {
    auto It = LogicalEscapeIDs.find(Key);
    if (It == LogicalEscapeIDs.end())
      It = LogicalEscapeIDs
               .try_emplace(Key, static_cast<uint32_t>(LogicalEscapeIDs.size()))
               .first;
    return It->second;
  };
  auto GetSourceID = [&](const BasicBlock *Key) {
    auto It = SourceIDs.find(Key);
    if (It == SourceIDs.end())
      It = SourceIDs.try_emplace(Key, static_cast<uint32_t>(SourceIDs.size()))
               .first;
    return It->second;
  };

  // Bucket effects by emit site. Effects without a resolved insertion point
  // cannot carry a batch and are skipped.
  for (jeandle::MaterializeEffect *ME : Effects) {
    Instruction *EmitSite =
        dyn_cast_or_null<Instruction>((Value *)ME->InsertBefore);
    if (!EmitSite)
      continue;

    auto [SiteIt, Inserted] = SiteIndex.try_emplace(EmitSite, Sites.size());
    if (Inserted) {
      Sites.push_back(EmitSite);
      SiteEffects.emplace_back();
    }
    SiteEffects[SiteIt->second].push_back(ME);
  }

  // Form one physical batch per lock-carrying site (lockless sites replay
  // only their fields and consume no batch). The site's highest-SeqNo effect
  // becomes EmitterSeqNo, the tail emitter that replays the merged list.
  for (unsigned SiteID = 0; SiteID < Sites.size(); ++SiteID) {
    ArrayRef<jeandle::MaterializeEffect *> EffectsAtSite = SiteEffects[SiteID];
    if (llvm::none_of(EffectsAtSite, [](jeandle::MaterializeEffect *ME) {
          return !ME->Locks.empty();
        }))
      continue;

    unsigned BatchID = LockReplayBatches.size();
    Instruction *EmitSite = Sites[SiteID];
    LockReplayBatchForSite.try_emplace(EmitSite, BatchID);
    LockReplayBatches.push_back({EmitSite, 0, 0, {}});
    BatchEffects.emplace_back();
    BatchEffects.back().append(EffectsAtSite.begin(), EffectsAtSite.end());
    for (jeandle::MaterializeEffect *ME : EffectsAtSite)
      LockReplayBatches.back().EmitterSeqNo =
          std::max(LockReplayBatches.back().EmitterSeqNo, ME->SeqNo);
    assert(llvm::count_if(EffectsAtSite,
                          [&](MaterializeEffect *ME) {
                            return ME->SeqNo ==
                                   LockReplayBatches.back().EmitterSeqNo;
                          }) == 1 &&
           "one physical lock replay batch must have exactly one tail emitter");
  }

  // Merge each batch's per-effect locks into MergedLocks: identical folded
  // enters dedup to one physical replay operation, and each effect's
  // LogicalEscape (falling back to the emit site) is recorded as a consumer.
  for (unsigned BatchID = 0; BatchID < LockReplayBatches.size(); ++BatchID) {
    LockReplayBatch &Batch = LockReplayBatches[BatchID];
    ArrayRef<jeandle::MaterializeEffect *> EffectsAtSite =
        BatchEffects[BatchID];
    for (jeandle::MaterializeEffect *ME : EffectsAtSite)
      assert((!ME->ReplaySource ||
              ME->ReplaySource == Batch.EmitSite->getParent()) &&
             "one physical replay site must have one source block");
    Batch.SourceID = GetSourceID(Batch.EmitSite->getParent());

    for (jeandle::MaterializeEffect *ME : EffectsAtSite) {
      const Value *LogicalEscape =
          ME->LogicalEscape ? ME->LogicalEscape : Batch.EmitSite;
      for (const jeandle::MaterializedLock &ML : ME->Locks) {
        // Defensive dedup: a physical batch must never contain the same
        // folded enter twice.
        jeandle::MergedLock *Existing = nullptr;
        for (jeandle::MergedLock &X : Batch.Locks) {
          if (X.Callee == ML.Callee && X.BytecodeDepth == ML.BytecodeDepth &&
              X.NonReceiverArgs.size() == ML.NonReceiverArgs.size() &&
              std::equal(X.NonReceiverArgs.begin(), X.NonReceiverArgs.end(),
                         ML.NonReceiverArgs.begin(),
                         [](const WeakTrackingVH &A, const WeakTrackingVH &B) {
                           return (Value *)A == (Value *)B;
                         })) {
            Existing = &X;
            break;
          }
        }
        if (!Existing) {
          Batch.Locks.push_back(
              {ML.Callee, ML.NonReceiverArgs, ML.BytecodeDepth, ME, {}});
          Existing = &Batch.Locks.back();
        }
        if (!llvm::is_contained(Existing->LogicalEscapes, LogicalEscape))
          Existing->LogicalEscapes.push_back(LogicalEscape);
      }
    }
  }

  // The runtime lock stack requires re-emission in strictly increasing depth
  // order, so each batch is globally sorted ascending by BytecodeDepth.
  for (LockReplayBatch &Batch : LockReplayBatches)
    llvm::sort(Batch.Locks,
               [](const jeandle::MergedLock &A, const jeandle::MergedLock &B) {
                 return A.BytecodeDepth < B.BytecodeDepth;
               });

  // Trace: one LockReplay row per (physical lock, logical consumer)
  // association, all sharing the lock's physical ordinal within the batch.
  if (!JeandleTracePEA)
    return;
  for (unsigned BatchID = 0; BatchID < LockReplayBatches.size(); ++BatchID) {
    const LockReplayBatch &Batch = LockReplayBatches[BatchID];
    Function *F = Batch.EmitSite ? Batch.EmitSite->getFunction() : nullptr;
    for (unsigned Ordinal = 0; Ordinal < Batch.Locks.size(); ++Ordinal) {
      const MergedLock &ML = Batch.Locks[Ordinal];
      if (!ML.SourceEffect || !ML.SourceEffect->hasMutationOwner())
        continue;
      for (const Value *LogicalEscape : ML.LogicalEscapes) {
        llvm::dbgs() << "PEA: LockReplay function=";
        if (F)
          F->printAsOperand(llvm::dbgs(), false);
        else
          llvm::dbgs() << "<unknown>";
        llvm::dbgs() << " logical_escape=" << GetLogicalEscapeID(LogicalEscape)
                     << " batch=" << BatchID << " source=" << Batch.SourceID
                     << " receiver_vo="
                     << static_cast<unsigned>(
                            ML.SourceEffect->getMutationOwner())
                     << " depth=" << ML.BytecodeDepth << " ordinal=" << Ordinal
                     << "\n";
      }
    }
  }
}

static void destroyUnparentedOwnedInstructions(
    ArrayRef<WeakTrackingVH> Phis, ArrayRef<WeakTrackingVH> Insts,
    ArrayRef<WeakTrackingVH> LoopFieldPhis = {}) {
  SmallPtrSet<Instruction *, 16> Seen;
  SmallVector<Instruction *, 16> ToDelete;
  auto Collect = [&](ArrayRef<WeakTrackingVH> Values) {
    for (const WeakTrackingVH &VH : Values)
      if (auto *I = dyn_cast_or_null<Instruction>((Value *)VH))
        if (!I->getParent() && Seen.insert(I).second)
          ToDelete.push_back(I);
  };

  Collect(LoopFieldPhis);
  Collect(Phis);
  Collect(Insts);

  // Analyzer-owned instructions may reference one another, for example a
  // load-replacement bitcast can use an unparented field PHI. Break all such
  // links before deleting any value, then destroy users before definitions.
  for (Instruction *I : ToDelete)
    I->dropAllReferences();
  for (Instruction *I : llvm::reverse(ToDelete))
    I->deleteValue();
}

PEAResult::~PEAResult() {
  // Once an analyzer-owned instruction has been inserted into a BasicBlock,
  // that block's ilist owns it. WeakTrackingVH also auto-nulls when an
  // unrelated cleanup path has already deleted the value.
  destroyUnparentedOwnedInstructions(OwnedPhis, OwnedInsts, OwnedLoopFieldPhis);
}

void PEAResult::truncateOwnedTo(size_t PhisMark, size_t InstsMark) {
  assert(PhisMark <= OwnedPhis.size() && InstsMark <= OwnedInsts.size());
  destroyUnparentedOwnedInstructions(
      ArrayRef(OwnedPhis).drop_front(PhisMark),
      ArrayRef(OwnedInsts).drop_front(InstsMark));
  OwnedPhis.resize(PhisMark);
  OwnedInsts.resize(InstsMark);
}

ObjectID PEAResult::createVirtualObject(std::unique_ptr<VirtualObject> VO) {
  assert(VO);
  ObjectID ID = static_cast<ObjectID>(VirtualObjects.size());
  // Re-stamp the ID. VirtualObject::ID is const, so use placement-new to
  // construct a fresh instance with the correct ID while keeping the rest of
  // the state intact.
  auto Stamped = std::make_unique<VirtualObject>(
      ID, VO->getKind(), cast_or_null<CallBase>((Value *)VO->AllocationCall));
  Stamped->copyStructuralFieldsFrom(*VO);
  VirtualObjects.push_back(std::move(Stamped));
  return ID;
}

void PEAResult::addBlockEffect(std::unique_ptr<Effect> E) {
  assert(E && E->hasValidMutationOwner() &&
         "only deopt-pool or placement effects may be ownerless");
  assert(E->Block);
  BasicBlock *BB = E->Block;
  BlockEffects[BB].add(std::move(E));
  ++EffectEpoch;
}

void PEAResult::publishEffectTrace() const {
  if (!JeandleTracePEA)
    return;
  SmallVector<const Effect *, 16> Effects;
  for (const auto &KV : BlockEffects)
    for (const Effect &E : KV.second)
      Effects.push_back(&E);
  llvm::sort(Effects, [](const Effect *A, const Effect *B) {
    return A->SeqNo < B->SeqNo;
  });
  for (const Effect *E : Effects) {
    E->dump(llvm::dbgs());
    llvm::dbgs() << "\n";
  }
}

bool PEAResult::hasUniqueEffectSequenceNumbers() const {
  DenseSet<uint32_t> Seen;
  for (const auto &KV : BlockEffects)
    for (const Effect &E : KV.second)
      if (!Seen.insert(E.SeqNo).second || E.SeqNo >= NextSeqNo)
        return false;
  return true;
}

bool PEAResult::hasLegalMaterializationAtomicTypes(const DataLayout &DL) const {
  for (const auto &KV : BlockEffects)
    for (const Effect &E : KV.second)
      if (const auto *ME = dyn_cast<MaterializeEffect>(&E))
        for (const MaterializeEffect::FieldEntry &FE : ME->FieldEntries)
          if (!pea::isLegalMaterializationAtomicType(FE.Value.getDeclaredType(),
                                                     DL))
            return false;
  return true;
}

void Effect::dump(raw_ostream &OS) const {
  OS << "PEA: ";
  switch (getKind()) {
  case Kind::ReplaceLoad:
    OS << "ReplaceLoad";
    break;
  case Kind::ReplaceCall:
    OS << "ReplaceCall";
    break;
  case Kind::EliminateStore:
    OS << "EliminateStore";
    break;
  case Kind::PlaceInstruction:
    OS << "PlaceInstruction";
    break;
  case Kind::EliminateAllocation:
    OS << "EliminateAllocation";
    break;
  case Kind::Materialize:
    OS << "Materialize";
    break;
  case Kind::CreatePHI:
    OS << "CreatePHI";
    break;
  case Kind::RewriteDeoptPool:
    OS << "RewriteDeoptPool";
    break;
  }
  if (Function *F = Block ? Block->getParent() : nullptr) {
    OS << " function=";
    F->printAsOperand(OS, false);
  }
  if (hasMutationOwner())
    OS << " [VO=" << static_cast<unsigned>(getMutationOwner()) << "]";
  if (Block && Block->hasName())
    OS << " block=%" << Block->getName();
  if (const auto *PE = dyn_cast<CreatePHIEffect>(this))
    OS << " offset=" << PE->FieldOffset;
  if (const auto *PE = dyn_cast<RewriteDeoptPoolEffect>(this))
    OS << " nodes=" << PE->getPlan().graph().nodes().size()
       << " current=" << PE->getPlan().graph().currentMembers().size()
       << " tokens=" << PE->getPlan().tokens().size();
  if (Instruction *T = getTarget())
    OS << " target= seq=" << SeqNo << " " << *T;
  else
    OS << " seq=" << SeqNo;
}

void MaterializeEffect::setInsertBefore(Instruction *I) { InsertBefore = I; }

RewriteDeoptPoolEffect::RewriteDeoptPoolEffect(
    CallBase *Safepoint,
    std::shared_ptr<const pea::FinalDeoptPoolBundlePlan> Plan)
    : SafepointKey(Safepoint), SafepointVH(Safepoint), Plan(std::move(Plan)) {
  assert(Safepoint && "deopt-pool rewrite requires a safepoint");
  assert(this->Plan && "deopt-pool rewrite requires an immutable plan");
}

Instruction *RewriteDeoptPoolEffect::getTarget() const {
  Value *Tracked = SafepointVH;
  return Tracked == SafepointKey ? SafepointKey : nullptr;
}

bool RewriteDeoptPoolEffect::coversExactOccurrence(unsigned SemanticCell,
                                                   ObjectID ID) const {
  return Plan->coversExactOccurrence(SemanticCell, ID);
}

bool RewriteDeoptPoolEffect::acceptsCurrentMember(ObjectID ID) const {
  return llvm::is_contained(Plan->graph().currentMembers(), ID);
}

bool PEAResult::currentIdentityRepresentsSource(ObjectID CurrentID,
                                                ObjectID SourceID) const {
  if (CurrentID == InvalidObjectID || SourceID == InvalidObjectID ||
      CurrentID >= VirtualObjects.size() || SourceID >= VirtualObjects.size())
    return false;

  DenseSet<ObjectID> Visited;
  SmallVector<ObjectID, 8> Worklist(1, CurrentID);
  while (!Worklist.empty()) {
    ObjectID ID = Worklist.pop_back_val();
    if (ID == InvalidObjectID || ID >= VirtualObjects.size() ||
        !Visited.insert(ID).second)
      continue;
    if (ID == SourceID)
      return true;
    const VirtualObject &VObj = *VirtualObjects[ID];
    if (!VObj.IsSynthetic)
      continue;
    Worklist.append(VObj.SyntheticSourceIDs.begin(),
                    VObj.SyntheticSourceIDs.end());
  }
  return false;
}

bool PEAResult::hasOptimizationOpportunity() const {
  // True when there is work for the transform: any net virtualization, any
  // recorded effect (folds and materializations must be applied even when no
  // allocation stays virtual on net), or an explicit CFG-cleanup obligation.
  // VirtualizationDelta and AllocationDelta are exact negations (see the
  // field doc) and VirtualizationDelta is never decremented below 0, so
  // VirtualizationDelta > 0 covers AllocationDelta != 0 and only one of the
  // two terms is tested.
  return VirtualizationDelta > 0 || !BlockEffects.empty() || NeedsCFGCleanup;
}
