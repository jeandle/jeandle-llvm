//===- PartialEscapeUtils.cpp - PEA helper implementations ------*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
// Pure helpers used by both the analysis and the transform pass.  No state.
// See PartialEscapeUtils.h for the interface.
//
//===----------------------------------------------------------------------===//

#include "llvm/Analysis/Jeandle/PartialEscapeUtils.h"

#include "llvm/ADT/APInt.h"
#include "llvm/ADT/DenseMapInfo.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/InstrTypes.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Jeandle/JavaType.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Operator.h"
#include "llvm/IR/Type.h"
#include "llvm/Support/CheckedArithmetic.h"
#include "llvm/Support/MathExtras.h"

#include <limits>

using namespace llvm;

namespace llvm::jeandle::pea {

// ===========================================================================
// Callee-name predicates
// ===========================================================================

bool isJeandleCallNamed(const CallBase *CB, StringRef Name) {
  if (!CB)
    return false;
  // Reject inline asm and indirect calls.
  if (CB->isInlineAsm())
    return false;
  const Function *F = CB->getCalledFunction();
  if (!F)
    return false;
  return F->getName() == Name;
}

bool isJeandleNewInstance(const CallBase *CB) {
  return isJeandleCallNamed(CB, "jeandle.new_instance");
}

bool isJeandleNewArray(const CallBase *CB) {
  return isJeandleCallNamed(CB, "jeandle.new_array");
}

bool isJeandleAllocation(const CallBase *CB) {
  return isJeandleNewInstance(CB) || isJeandleNewArray(CB);
}

bool isJeandleArrayLength(const CallBase *CB) {
  return isJeandleCallNamed(CB, "jeandle.arraylength");
}

bool isJeandleLoadKlass(const CallBase *CB) {
  return isJeandleCallNamed(CB, "jeandle.load_klass");
}

bool isJeandleGetClass(const CallBase *CB) {
  return isJeandleCallNamed(CB, "jeandle.get_class");
}

bool isJeandleCheckCast(const CallBase *CB) {
  return isJeandleCallNamed(CB, "jeandle.checkcast");
}

bool isJeandleInstanceOf(const CallBase *CB) {
  return isJeandleCallNamed(CB, "jeandle.instanceof");
}

bool isJeandleCheckInstanceOf(const CallBase *CB) {
  return isJeandleCallNamed(CB, "jeandle.check_instanceof");
}

bool isJeandleCheckIfValueBased(const CallBase *CB) {
  return isJeandleCallNamed(CB, "jeandle.check_if_value_based");
}

bool isJeandleArrayStoreCheck(const CallBase *CB) {
  return isJeandleCallNamed(CB, "jeandle.array_store_check");
}

bool isJeandlePostBarrier(const CallBase *CB) {
  return isJeandleCallNamed(CB, "jeandle.post_barrier");
}

bool isJeandleMonitorEnter(const CallBase *CB) {
  return isJeandleCallNamed(CB, "jeandle.monitorenter_with_monitor_lock") ||
         isJeandleCallNamed(CB, "jeandle.monitorenter_with_thin_lock") ||
         isJeandleCallNamed(CB, "jeandle.monitorenter_with_lightweight_lock");
}

bool isJeandleMonitorExit(const CallBase *CB) {
  return isJeandleCallNamed(CB, "jeandle.monitorexit_with_monitor_lock") ||
         isJeandleCallNamed(CB, "jeandle.monitorexit_with_thin_lock") ||
         isJeandleCallNamed(CB, "jeandle.monitorexit_with_lightweight_lock");
}

bool isJeandleRegisterFinalizerIfNeeded(const CallBase *CB) {
  return isJeandleCallNamed(CB, "jeandle.register_finalizer_if_needed");
}

bool isPEAHandledNonEscapingIntrinsic(const IntrinsicInst *II) {
  if (!II)
    return false;
  switch (II->getIntrinsicID()) {
  case Intrinsic::assume:
  case Intrinsic::lifetime_start:
  case Intrinsic::lifetime_end:
  case Intrinsic::invariant_start:
  case Intrinsic::invariant_end:
  case Intrinsic::experimental_noalias_scope_decl:
  case Intrinsic::dbg_declare:
  case Intrinsic::dbg_value:
  case Intrinsic::dbg_label:
  case Intrinsic::donothing:
  case Intrinsic::sideeffect:
  case Intrinsic::var_annotation:
  case Intrinsic::is_constant:
  case Intrinsic::expect:
  case Intrinsic::expect_with_probability:
  case Intrinsic::allow_runtime_check:
  case Intrinsic::allow_ubsan_check:
  case Intrinsic::launder_invariant_group:
  case Intrinsic::strip_invariant_group:
  case Intrinsic::ptr_annotation:
    return true;
  default:
    return false;
  }
}

// ===========================================================================
// Type / klass helpers
// ===========================================================================

Type *llvmElementTypeFor(JBasicType Kind, LLVMContext &Ctx) {
  switch (Kind) {
  case JBasicType::Boolean:
    return Type::getInt1Ty(Ctx);
  case JBasicType::Byte:
    return Type::getInt8Ty(Ctx);
  case JBasicType::Char:
    return Type::getInt16Ty(Ctx);
  case JBasicType::Short:
    return Type::getInt16Ty(Ctx);
  case JBasicType::Int:
    return Type::getInt32Ty(Ctx);
  case JBasicType::Long:
    return Type::getInt64Ty(Ctx);
  case JBasicType::Float:
    return Type::getFloatTy(Ctx);
  case JBasicType::Double:
    return Type::getDoubleTy(Ctx);
  case JBasicType::Object:
    return PointerType::get(Ctx, jeandle::AddrSpace::JavaHeapAddrSpace);
  case JBasicType::Count:
    return nullptr;
  }
  return nullptr;
}

bool isLegalMaterializationAtomicType(Type *Ty, const DataLayout &DL) {
  if (!Ty || !Ty->isSized())
    return false;

  Type *ScalarTy = Ty->getScalarType();
  if (!ScalarTy->isIntOrPtrTy() && !ScalarTy->isFloatingPointTy())
    return false;

  TypeSize Bits = DL.getTypeSizeInBits(Ty);
  if (Bits.isScalable())
    return false;
  uint64_t FixedBits = Bits.getFixedValue();
  return FixedBits >= 8 && isPowerOf2_64(FixedBits);
}

std::optional<int64_t> checkedOffsetAdd(int64_t LHS, int64_t RHS) {
  return checkedAdd(LHS, RHS);
}

std::optional<int64_t> checkedOffsetSub(int64_t LHS, int64_t RHS) {
  return checkedSub(LHS, RHS);
}

std::optional<int64_t> checkedArrayElementOffset(int64_t Base, int64_t Index,
                                                 uint64_t Scale) {
  if (Scale > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))
    return std::nullopt;
  return checkedMulAdd(Index, static_cast<int64_t>(Scale), Base);
}

bool isUsableFieldOffset(int64_t Offset) {
  return Offset != DenseMapInfo<int64_t>::getEmptyKey() &&
         Offset != DenseMapInfo<int64_t>::getTombstoneKey();
}

std::optional<bool> checkedRangesOverlap(int64_t AStart, uint64_t ASize,
                                         int64_t BStart, uint64_t BSize) {
  if (ASize == 0 || BSize == 0)
    return false;
  if (ASize > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) ||
      BSize > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))
    return std::nullopt;
  std::optional<int64_t> AEnd =
      checkedOffsetAdd(AStart, static_cast<int64_t>(ASize));
  std::optional<int64_t> BEnd =
      checkedOffsetAdd(BStart, static_cast<int64_t>(BSize));
  if (!AEnd || !BEnd)
    return std::nullopt;
  return AStart < *BEnd && BStart < *AEnd;
}

// ===========================================================================
// Structural pointer chain walker
// ===========================================================================

// If V is `inttoptr(ptrtoint(x))` with matching pointer/int bit widths — a
// legal pointer-laundering round-trip — return x (the ptrtoint's pointer
// operand, after stripping offset-neutral `add/or X,0` chains the frontend
// may emit between the two casts). Tagged/masked encodings (any non-zero
// addend) are NOT round-trips and return nullptr.
//
// Shared by resolveVirtualIdentityImpl (identity resolution, case (7)) and
// stripPointerCastsAndOffsets (offset resolution) so the two agree on exactly
// which laundered pointers are transparent: an `inttoptr` that is NOT a clean
// round-trip is opaque to both (identity -> Unknown, offset -> stop walking).
// Recognize an IntToPtr over both Instruction and ConstantExpr forms. LLVM
// has `PtrToIntOperator` but no `IntToPtrOperator`, so match via the generic
// Operator + opcode. Used at both call sites so identity and offset
// wrapper-stripping stay symmetric for the round-trip.
static bool isIntToPtrOp(const Value *V) {
  if (auto *Op = dyn_cast<Operator>(V))
    return Op->getOpcode() == Instruction::IntToPtr;
  return false;
}

static Value *getIntToPtrRoundTripInner(Value *V, const DataLayout &DL) {
  if (!isIntToPtrOp(V))
    return nullptr;
  auto *I2P = cast<Operator>(V);
  Value *Inner = I2P->getOperand(0);
  // Peel `add X, 0` / `or X, 0` chains between PtrToInt and IntToPtr; some
  // frontends emit these as part of constant-folded address arithmetic and
  // they are transparent (offset-neutral) to the round-trip. Use Operator +
  // opcode so ConstantExpr `add`/`or` is peeled too.
  for (unsigned StripDepth = 0; StripDepth < 8; ++StripDepth) {
    auto *BO = dyn_cast<Operator>(Inner);
    if (BO && (BO->getOpcode() == Instruction::Add ||
               BO->getOpcode() == Instruction::Or)) {
      if (auto *RHS = dyn_cast<ConstantInt>(BO->getOperand(1));
          RHS && RHS->isZero()) {
        Inner = BO->getOperand(0);
        continue;
      }
      if (auto *LHS = dyn_cast<ConstantInt>(BO->getOperand(0));
          LHS && LHS->isZero() && BO->getOpcode() == Instruction::Add) {
        Inner = BO->getOperand(1);
        continue;
      }
    }
    break;
  }
  // PtrToIntOperator covers both PtrToIntInst and ConstantExprPtrToInt.
  auto *P2I = dyn_cast<PtrToIntOperator>(Inner);
  if (!P2I)
    return nullptr;
  Type *PtrTy = P2I->getPointerOperand()->getType();
  if (auto *PT = dyn_cast<PointerType>(PtrTy)) {
    unsigned AS = PT->getAddressSpace();
    unsigned PtrBits = DL.getPointerSizeInBits(AS);
    unsigned IntBits = P2I->getType()->getIntegerBitWidth();
    if (PtrBits == IntBits)
      return P2I->getPointerOperand();
  }
  return nullptr;
}

Value *stripPointerCastsAndOffsets(Value *Ptr, const DataLayout &DL,
                                   int64_t *OutOffset, bool *Unresolved) {
  if (OutOffset)
    *OutOffset = 0;
  if (Unresolved)
    *Unresolved = false;
  if (!Ptr)
    return nullptr;

  int64_t Offset = 0;
  Value *V = Ptr;
  // Bound the walk defensively; Jeandle IR typically has < 5 layers.
  for (unsigned Depth = 0; Depth < 32; ++Depth) {
    if (auto *GEP = dyn_cast<GEPOperator>(V)) {
      const unsigned AS = GEP->getPointerAddressSpace();
      const unsigned IndexBits = DL.getIndexSizeInBits(AS);
      APInt Acc(IndexBits, 0, /*isSigned=*/true);
      if (!GEP->accumulateConstantOffset(DL, Acc)) {
        if (Unresolved)
          *Unresolved = true;
        return V;
      }
      std::optional<int64_t> GEPDelta = Acc.trySExtValue();
      std::optional<int64_t> NewOffset =
          GEPDelta ? checkedOffsetAdd(Offset, *GEPDelta) : std::nullopt;
      if (!NewOffset) {
        if (Unresolved)
          *Unresolved = true;
        return V;
      }
      Offset = *NewOffset;
      V = GEP->getPointerOperand();
      continue;
    }
    if (auto *BC = dyn_cast<BitCastOperator>(V)) {
      // Cross-address-space bitcasts are illegal IR; addrspacecast is required.
      // We don't assert here (this is a util used over arbitrary IR); just
      // continue on the inner operand.
      V = BC->getOperand(0);
      continue;
    }
    if (auto *ASC = dyn_cast<AddrSpaceCastOperator>(V)) {
      // Only chase through casts that stay in JavaHeapAddrSpace.
      auto *DstPT = dyn_cast<PointerType>(ASC->getType());
      auto *SrcPT = dyn_cast<PointerType>(ASC->getOperand(0)->getType());
      if (!DstPT || !SrcPT) {
        if (OutOffset)
          *OutOffset = Offset;
        return V;
      }
      if (DstPT->getAddressSpace() != jeandle::AddrSpace::JavaHeapAddrSpace ||
          SrcPT->getAddressSpace() != jeandle::AddrSpace::JavaHeapAddrSpace) {
        if (OutOffset)
          *OutOffset = Offset;
        return V;
      }
      V = ASC->getOperand(0);
      continue;
    }
    if (auto *FI = dyn_cast<FreezeInst>(V)) {
      V = FI->getOperand(0);
      continue;
    }
    // llvm.launder/strip.invariant.group and llvm.ptr.annotation are
    // pointer-identity-preserving.
    // resolveVirtualRef sees them through the alias map (processIntrinsic
    // installs it); offset resolution must peel them too, so a wrapped GEP
    // keeps its accumulated byte offset.
    if (auto *II = dyn_cast<IntrinsicInst>(V)) {
      Intrinsic::ID ID = II->getIntrinsicID();
      if (ID == Intrinsic::launder_invariant_group ||
          ID == Intrinsic::strip_invariant_group ||
          ID == Intrinsic::ptr_annotation) {
        V = II->getArgOperand(0);
        continue;
      }
    }
    // inttoptr(ptrtoint(x)) same-width round-trip (legal laundering): peel to
    // x so any GEP inside the round-trip contributes its offset. A non-round-
    // trip inttoptr is opaque — stop here. (resolveVirtualRef would not have
    // resolved such a pointer to a virtual, so the offset is unused there.)
    // getIntToPtrRoundTripInner uses Operator-form casts so a ConstantExpr
    // round-trip is peeled the same as an Instruction-form one — keeping this
    // offset path symmetric with the identity path.
    if (Value *Inner = getIntToPtrRoundTripInner(V, DL)) {
      V = Inner;
      continue;
    }
    break;
  }
  if (OutOffset)
    *OutOffset = Offset;
  return V;
}

// ===========================================================================
// Virtual identity resolution
// ===========================================================================

// Bound on structural recursion through PHI/Select. With Visited-set cycle
// detection the recursion is already bounded by the IR structure, but a hard
// depth cap prevents pathological diamond DAGs from causing exponential
// expansion through repeated PHI/Select operands.
static constexpr unsigned ResolveVirtualRefMaxDepth = 8;

static VirtualIdentityResult
resolveVirtualIdentityImpl(Value *V, const PEABlockState &State,
                           const AliasMap &Aliases, const DataLayout &DL,
                           VirtualIdentityMode Mode,
                           SmallDenseSet<Value *, 8> &Visited, unsigned Depth);

// RAII helper: insert `V` into `Visited` on entry and erase on scope exit so
// that the set tracks "values currently on the DFS stack", not "values ever
// seen". The on-stack semantics correctly detect cycles (re-entering a value
// already being resolved) without rejecting legitimate diamond patterns where
// two sibling subtrees share a value (e.g. `select i1 %c, %o, %o`).
namespace {
struct StackGuard {
  SmallDenseSet<Value *, 8> &Set;
  Value *V;
  bool Inserted;
  StackGuard(SmallDenseSet<Value *, 8> &S, Value *Val) : Set(S), V(Val) {
    Inserted = Set.insert(V).second;
  }
  ~StackGuard() {
    if (Inserted)
      Set.erase(V);
  }
};
} // namespace

// Core of virtual-identity resolution, shared by resolveVirtualIdentity and
// (in WholeObject mode) isProvablyDistinctFromVirtual. Resolution proceeds in
// priority order: the AliasMap first (authoritative for alias-registered
// Values such as loads and already-processed PHIs, which have no structural
// relationship with their allocation site), then constants (poison is a
// refinement wildcard; null, undef, globals, and numeric constants are never
// a virtual object), then carrier peeling (GEP, addrspacecast within
// JavaHeapAddrSpace, bitcast, freeze, same-width inttoptr(ptrtoint(x))
// round-trips), and finally PHI/select merge resolution, where the merge
// denotes a virtual object only when every defined alternative resolves to
// the same ObjectID, with poison refining to that identity. WholeObject mode
// additionally requires offset zero on every path. Recursion is depth-capped
// at ResolveVirtualRefMaxDepth and cycle-guarded by the on-stack Visited set
// (see StackGuard), so pathological merge graphs degrade to Unknown instead
// of diverging. Unknown means "may denote anything": callers materialize.
static VirtualIdentityResult
resolveVirtualIdentityImpl(Value *V, const PEABlockState &State,
                           const AliasMap &Aliases, const DataLayout &DL,
                           VirtualIdentityMode Mode,
                           SmallDenseSet<Value *, 8> &Visited, unsigned Depth) {
  if (!V)
    return VirtualIdentityResult::unknown();
  if (Depth > ResolveVirtualRefMaxDepth)
    return VirtualIdentityResult::unknown();
  // Cycle detection: if V is already on the resolution stack we're in a
  // self-reference (e.g. phi referencing itself) — bail.
  StackGuard Guard(Visited, V);
  if (!Guard.Inserted)
    return VirtualIdentityResult::unknown();

  // (1) Alias map lookup takes precedence over structural peeling so that
  // alias-registered Values (loads, PHIs, ...) resolve correctly even though
  // they have no structural relationship with their allocation site. The
  // virtual and scalar aliases are each read exactly once here.
  auto VirtAlias = Aliases.getVirtualAlias(V);
  Value *ScalarAlias = Aliases.getScalarAlias(V);
  if (VirtAlias || ScalarAlias) {
    if (VirtAlias) {
      if (Mode == VirtualIdentityMode::WholeObject &&
          !Aliases.isWholeObjectVirtualAlias(V))
        return VirtualIdentityResult::unknown();
      if (const ObjectState *OS = State.getObjectStateOptional(*VirtAlias)) {
        if (OS->isVirtual())
          return VirtualIdentityResult::defined(*VirtAlias);
      }
      return VirtualIdentityResult::unknown();
    }
    // Scalar-replacement aliases never denote a virtual object.
    return VirtualIdentityResult::unknown();
  }

  // (2) Constants and special values.
  if (auto *C = dyn_cast<Constant>(V)) {
    if (isa<PoisonValue>(C))
      return VirtualIdentityResult::poisonWildcard();
    if (C->isNullValue() || isa<UndefValue>(C) || isa<GlobalValue>(C) ||
        isa<ConstantInt>(C) || isa<ConstantFP>(C) ||
        isa<ConstantPointerNull>(C))
      return VirtualIdentityResult::unknown();
    // ConstantExpr GEP/cast falls through to the structural cases below.
  }

  // (3) GEP — chase the base pointer (offset is resolveFieldOffset's job).
  if (auto *GEP = dyn_cast<GEPOperator>(V)) {
    if (Mode == VirtualIdentityMode::WholeObject) {
      std::optional<int64_t> Offset = resolveFieldOffset(V, DL);
      if (!Offset || *Offset != 0)
        return VirtualIdentityResult::unknown();
    }
    return resolveVirtualIdentityImpl(GEP->getPointerOperand(), State, Aliases,
                                      DL, Mode, Visited, Depth + 1);
  }

  // (4) AddrSpaceCast — only chase within JavaHeapAddrSpace.
  if (auto *ASC = dyn_cast<AddrSpaceCastOperator>(V)) {
    if (auto *DstPT = dyn_cast<PointerType>(ASC->getType()))
      if (DstPT->getAddressSpace() != jeandle::AddrSpace::JavaHeapAddrSpace)
        return VirtualIdentityResult::unknown();
    if (auto *SrcPT = dyn_cast<PointerType>(ASC->getOperand(0)->getType()))
      if (SrcPT->getAddressSpace() != jeandle::AddrSpace::JavaHeapAddrSpace)
        return VirtualIdentityResult::unknown();
    return resolveVirtualIdentityImpl(ASC->getOperand(0), State, Aliases, DL,
                                      Mode, Visited, Depth + 1);
  }

  // (5) BitCast.
  if (auto *BC = dyn_cast<BitCastOperator>(V))
    return resolveVirtualIdentityImpl(BC->getOperand(0), State, Aliases, DL,
                                      Mode, Visited, Depth + 1);

  // (6) Freeze preserves only an already-defined identity. Freezing poison,
  // undef, or an unresolved merge creates an arbitrary stable value, not a
  // virtual-object identity.
  if (auto *FI = dyn_cast<FreezeInst>(V)) {
    VirtualIdentityResult Inner = resolveVirtualIdentityImpl(
        FI->getOperand(0), State, Aliases, DL, Mode, Visited, Depth + 1);
    return Inner.isDefined() ? Inner : VirtualIdentityResult::unknown();
  }

  // (7) IntToPtr(PtrToInt(x)) round-trip with matching widths is a legal
  // laundering pattern (see getIntToPtrRoundTripInner); tagged-pointer
  // encodings (with masking/shifting) must escape. A non-round-trip inttoptr
  // is opaque — return Unknown so the caller materializes. isIntToPtrOp
  // covers both Instruction and ConstantExpr forms, keeping this symmetric
  // with the offset-resolution path in stripPointerCastsAndOffsets.
  if (isIntToPtrOp(V)) {
    if (Value *Inner = getIntToPtrRoundTripInner(V, DL))
      return resolveVirtualIdentityImpl(Inner, State, Aliases, DL, Mode,
                                        Visited, Depth + 1);
    return VirtualIdentityResult::unknown();
  }

  // (8) PHINode / (9) SelectInst — recursion through merges that the
  // AliasMap did not pre-register as aliases (e.g. PHIs outside the current
  // BlockState domain, chained PHIs not yet processed, or Selects, which are
  // never pre-registered because alias registration only covers PHIs). If
  // every operand resolves to the same ObjectID, the merge denotes that
  // virtual object on every execution path. (This is the resolver-side
  // counterpart of a "Case B" merge: a pointer PHI whose incoming values all
  // resolve to the SAME still-virtual object, so the PHI is registered as
  // that object's alias.) StackGuard guarantees that Visited reverts to the
  // caller's state on every return path, so a sibling subtree that shares a
  // value with an earlier sibling can still descend through it.
  if (auto *Phi = dyn_cast<PHINode>(V)) {
    std::optional<ObjectID> Common;
    for (Value *In : Phi->incoming_values()) {
      VirtualIdentityResult Sub = resolveVirtualIdentityImpl(
          In, State, Aliases, DL, Mode, Visited, Depth + 1);
      if (Sub.isPoisonWildcard())
        continue;
      if (!Sub.isDefined())
        return VirtualIdentityResult::unknown();
      if (!Common)
        Common = Sub.getObjectID();
      else if (Sub.getObjectID() != *Common)
        return VirtualIdentityResult::unknown();
    }
    if (Common)
      return VirtualIdentityResult::defined(*Common);
    // A merge made entirely from poison has no defined identity to refine.
    return VirtualIdentityResult::unknown();
  }

  if (auto *Sel = dyn_cast<SelectInst>(V)) {
    VirtualIdentityResult T = resolveVirtualIdentityImpl(
        Sel->getTrueValue(), State, Aliases, DL, Mode, Visited, Depth + 1);
    VirtualIdentityResult F = resolveVirtualIdentityImpl(
        Sel->getFalseValue(), State, Aliases, DL, Mode, Visited, Depth + 1);
    if (T.isPoisonWildcard() && F.isDefined())
      return F;
    if (F.isPoisonWildcard() && T.isDefined())
      return T;
    if (T.isDefined() && F.isDefined() && T.getObjectID() == F.getObjectID())
      return T;
    // In particular, all-poison selects are Unknown, as are any merges
    // involving undef/external values or differing defined identities.
    return VirtualIdentityResult::unknown();
  }

  // (10) Call, Argument, ... — opaque to alias analysis. Fall through.
  return VirtualIdentityResult::unknown();
}

VirtualIdentityResult resolveVirtualIdentity(Value *V,
                                             const PEABlockState &State,
                                             const AliasMap &Aliases,
                                             const DataLayout &DL,
                                             VirtualIdentityMode Mode) {
  SmallDenseSet<Value *, 8> Visited;
  return resolveVirtualIdentityImpl(V, State, Aliases, DL, Mode, Visited,
                                    /*Depth=*/0);
}

std::optional<ObjectID> resolveVirtualRef(Value *V, const PEABlockState &State,
                                          const AliasMap &Aliases,
                                          const DataLayout &DL) {
  VirtualIdentityResult R = resolveVirtualIdentity(
      V, State, Aliases, DL, VirtualIdentityMode::BaseObject);
  if (!R.isDefined())
    return std::nullopt;
  return R.getObjectID();
}

// Recursive proof engine behind isProvablyDistinctFromVirtual: returns true
// only when V provably cannot denote TargetID's (unpublished) allocation.
// Proof routes, tried in order:
//  - whole-object identity: V resolves in WholeObject mode to a different
//    still-virtual object;
//  - stale alias: the AliasMap still ties V to a different allocation and V
//    is that allocation's offset-zero address (a materialized object fails
//    resolution through State, but its recorded identity still excludes
//    TargetID);
//  - scalar-alias unwrapping;
//  - PHI/select conjunction: every alternative is provably distinct;
//  - carrier peeling: freeze of a provably-defined operand, offset-zero GEP,
//    bitcast, JavaHeap addrspacecast, same-width inttoptr(ptrtoint(x))
//    round-trip, launder/strip.invariant.group, ptr.annotation;
//  - terminal rule: null and globals are always distinct, and a direct
//    Argument/Load/Call result cannot denote an unpublished virtual
//    allocation. Poison, undef, other constants, and any unrecognized
//    pointer-producing structure fail the proof: they may be carriers for
//    TargetID.
// Depth-capped and on-stack-cycle-guarded exactly like identity resolution.
static bool isProvablyDistinctFromVirtualImpl(
    Value *V, ObjectID TargetID, const PEABlockState &State,
    const AliasMap &Aliases, const DataLayout &DL,
    SmallDenseSet<Value *, 8> &Visited,
    SmallDenseSet<Value *, 8> &IdentityScratch, unsigned Depth) {
  if (!V || Depth > ResolveVirtualRefMaxDepth)
    return false;
  StackGuard Guard(Visited, V);
  if (!Guard.Inserted)
    return false;

  // Poison and undef may refine to any value, including TargetID's object,
  // so distinctness is never provable for them.
  if (isa<PoisonValue>(V) || isa<UndefValue>(V))
    return false;

  // Reuse a single scratch set across recursion nodes instead of allocating a
  // fresh visited-set per call. clear() restores the empty-set semantics the
  // public wrapper relied on; the outer Visited already contains V here, so the
  // two sets must stay distinct.
  IdentityScratch.clear();
  VirtualIdentityResult Whole = resolveVirtualIdentityImpl(
      V, State, Aliases, DL, VirtualIdentityMode::WholeObject, IdentityScratch,
      /*Depth=*/0);
  if (Whole.isDefined())
    return Whole.getObjectID() != TargetID;

  // A materialized/stale alias fails the WholeObject resolution above
  // because its object is not virtual in State, but the AliasMap still
  // records its allocation identity. Only its whole-object address can
  // participate in the allocation-site distinctness proof.
  if (auto AliasID = Aliases.getVirtualAlias(V)) {
    std::optional<int64_t> Offset = resolveFieldOffset(V, DL);
    return Offset && *Offset == 0 && *AliasID != TargetID;
  }
  if (Value *Scalar = Aliases.getScalarAlias(V))
    return isProvablyDistinctFromVirtualImpl(Scalar, TargetID, State, Aliases,
                                             DL, Visited, IdentityScratch,
                                             Depth + 1);

  // Merge conjunction: a PHI/select can denote TargetID only when some
  // feasible alternative can, so it is provably distinct exactly when every
  // alternative is. (An empty PHI conservatively fails.)
  if (auto *PN = dyn_cast<PHINode>(V)) {
    if (PN->getNumIncomingValues() == 0)
      return false;
    return llvm::all_of(PN->incoming_values(), [&](Value *Incoming) {
      return isProvablyDistinctFromVirtualImpl(Incoming, TargetID, State,
                                               Aliases, DL, Visited,
                                               IdentityScratch, Depth + 1);
    });
  }
  if (auto *Sel = dyn_cast<SelectInst>(V))
    return isProvablyDistinctFromVirtualImpl(Sel->getTrueValue(), TargetID,
                                             State, Aliases, DL, Visited,
                                             IdentityScratch, Depth + 1) &&
           isProvablyDistinctFromVirtualImpl(Sel->getFalseValue(), TargetID,
                                             State, Aliases, DL, Visited,
                                             IdentityScratch, Depth + 1);

  // Freeze makes an undef/poison choice observable. Recurse only when LLVM
  // can prove its operand already has a defined value.
  if (auto *FI = dyn_cast<FreezeInst>(V))
    return isGuaranteedNotToBeUndefOrPoison(FI->getOperand(0)) &&
           isProvablyDistinctFromVirtualImpl(FI->getOperand(0), TargetID, State,
                                             Aliases, DL, Visited,
                                             IdentityScratch, Depth + 1);

  if (auto *GEP = dyn_cast<GEPOperator>(V)) {
    std::optional<int64_t> Offset = resolveFieldOffset(V, DL);
    return Offset && *Offset == 0 &&
           isProvablyDistinctFromVirtualImpl(GEP->getPointerOperand(), TargetID,
                                             State, Aliases, DL, Visited,
                                             IdentityScratch, Depth + 1);
  }
  if (auto *BC = dyn_cast<BitCastOperator>(V))
    return isProvablyDistinctFromVirtualImpl(BC->getOperand(0), TargetID, State,
                                             Aliases, DL, Visited,
                                             IdentityScratch, Depth + 1);
  if (auto *ASC = dyn_cast<AddrSpaceCastOperator>(V)) {
    auto *SrcPT = dyn_cast<PointerType>(ASC->getOperand(0)->getType());
    auto *DstPT = dyn_cast<PointerType>(ASC->getType());
    if (!SrcPT || !DstPT ||
        SrcPT->getAddressSpace() != jeandle::AddrSpace::JavaHeapAddrSpace ||
        DstPT->getAddressSpace() != jeandle::AddrSpace::JavaHeapAddrSpace)
      return false;
    return isProvablyDistinctFromVirtualImpl(ASC->getOperand(0), TargetID,
                                             State, Aliases, DL, Visited,
                                             IdentityScratch, Depth + 1);
  }
  if (isIntToPtrOp(V)) {
    Value *Inner = getIntToPtrRoundTripInner(V, DL);
    return Inner && isProvablyDistinctFromVirtualImpl(
                        Inner, TargetID, State, Aliases, DL, Visited,
                        IdentityScratch, Depth + 1);
  }

  if (auto *II = dyn_cast<IntrinsicInst>(V)) {
    switch (II->getIntrinsicID()) {
    case Intrinsic::launder_invariant_group:
    case Intrinsic::strip_invariant_group:
    case Intrinsic::ptr_annotation:
      return isProvablyDistinctFromVirtualImpl(II->getArgOperand(0), TargetID,
                                               State, Aliases, DL, Visited,
                                               IdentityScratch, Depth + 1);
    default:
      return false;
    }
  }

  if (isa<ConstantPointerNull>(V) || isa<GlobalValue>(V))
    return true;
  if (isa<Constant>(V))
    return false;

  // A still-virtual allocation has not been published. A direct external SSA
  // reference cannot denote it. Unknown pointer-producing structure is not
  // accepted: it may merely be another carrier for TargetID.
  return isa<Argument>(V) || isa<LoadInst>(V) || isa<CallBase>(V);
}

bool isProvablyDistinctFromVirtual(Value *V, ObjectID TargetID,
                                   const PEABlockState &State,
                                   const AliasMap &Aliases,
                                   const DataLayout &DL) {
  assert(TargetID != InvalidObjectID);
  SmallDenseSet<Value *, 8> Visited;
  SmallDenseSet<Value *, 8> IdentityScratch;
  return isProvablyDistinctFromVirtualImpl(V, TargetID, State, Aliases, DL,
                                           Visited, IdentityScratch,
                                           /*Depth=*/0);
}

// ===========================================================================
// resolveFieldOffset
// ===========================================================================

std::optional<int64_t> resolveFieldOffset(Value *Ptr, const DataLayout &DL) {
  if (!Ptr)
    return std::nullopt;
  // Delegate to the shared offset accumulator so identity- and
  // offset-resolution peel the same set of wrappers (GEP constant offsets,
  // bitcast, JavaHeap addrspacecast, freeze, launder/strip.invariant.group,
  // ptr.annotation, inttoptr(ptrtoint(x)) round-trip): a pointer that resolves
  // to a virtual base yields its true byte offset here. A non-constant GEP ->
  // nullopt (caller materializes); a non-GEP base (the object itself, or a
  // merge with a defined whole-object identity) -> 0.
  int64_t Off = 0;
  bool NonConst = false;
  stripPointerCastsAndOffsets(Ptr, DL, &Off, &NonConst);
  if (NonConst || !isUsableFieldOffset(Off))
    return std::nullopt;
  return Off;
}

bool hasUnremovedSemanticUses(Value *Root,
                              function_ref<bool(const Use &)> IsRemoved) {
  SmallPtrSet<Value *, 16> Visited;
  SmallVector<Value *, 16> Worklist(1, Root);
  // Walk users transitively: carrier instructions forward the pointer value
  // without observing it, so the walk continues through them; every other
  // (semantic) use must be accepted by IsRemoved.
  while (!Worklist.empty()) {
    Value *Current = Worklist.pop_back_val();
    if (!Current || !Visited.insert(Current).second)
      continue;
    for (const Use &U : Current->uses()) {
      auto *I = dyn_cast<Instruction>(U.getUser());
      bool IsCarrier = I && (isa<GetElementPtrInst>(I) || isa<BitCastInst>(I) ||
                             isa<AddrSpaceCastInst>(I) || isa<FreezeInst>(I) ||
                             isa<PHINode>(I) || isa<SelectInst>(I));
      if (auto *II = dyn_cast_or_null<IntrinsicInst>(I)) {
        Intrinsic::ID ID = II->getIntrinsicID();
        IsCarrier = U.getOperandNo() == 0 &&
                    (ID == Intrinsic::launder_invariant_group ||
                     ID == Intrinsic::strip_invariant_group ||
                     ID == Intrinsic::ptr_annotation);
      }
      if (IsCarrier) {
        Worklist.push_back(I);
        continue;
      }
      if (!IsRemoved(U))
        return true;
    }
  }
  return false;
}

// ===========================================================================
// Misc
// ===========================================================================

uintptr_t extractAllocationKlass(const CallBase *AllocCB) {
  if (!AllocCB || AllocCB->arg_size() == 0)
    return 0;
  // Both jeandle.new_instance and jeandle.new_array take the klass pointer as
  // their first operand.
  return jeandle::extractKlassConstant(
      const_cast<Value *>(AllocCB->getArgOperand(0)));
}

std::optional<uint32_t> extractInstanceSize(const CallBase *NewInstance) {
  if (!isJeandleNewInstance(NewInstance) || NewInstance->arg_size() < 2)
    return std::nullopt;
  auto *CI = dyn_cast<ConstantInt>(NewInstance->getArgOperand(1));
  if (!CI)
    return std::nullopt;
  return static_cast<uint32_t>(CI->getZExtValue());
}

std::optional<uint32_t> extractArrayLength(const CallBase *NewArray) {
  if (!isJeandleNewArray(NewArray) || NewArray->arg_size() != 5)
    return std::nullopt;
  auto *CI = dyn_cast<ConstantInt>(NewArray->getArgOperand(1));
  if (!CI)
    return std::nullopt;
  return static_cast<uint32_t>(CI->getZExtValue());
}

// ===========================================================================
// Deopt bundle scope structure
// ===========================================================================

// Decode a raw deopt-value encoding constant into its checked form. Bit
// layout of the i64: [63:32] = index (signed), [31:16] = deopt value type,
// [15:0] = HotSpot basic type. This is the assertion-free counterpart of
// DeoptValueEncoding::decode: non-constant or non-i64 inputs and out-of-range
// value/basic types yield std::nullopt instead of trapping, so the parser is
// safe to run on arbitrary IR.
std::optional<CheckedDeoptValueEncoding>
decodeDeoptValueEncoding(const Value *V) {
  auto *CI = dyn_cast_or_null<ConstantInt>(V);
  if (!CI || !CI->getType()->isIntegerTy(64))
    return std::nullopt;

  uint64_t Raw = CI->getZExtValue();
  uint16_t RawValueType = static_cast<uint16_t>((Raw >> 16) & 0xffff);
  DeoptValueEncoding::DeoptValueType ValueType;
  switch (RawValueType) {
  case DeoptValueEncoding::LocalType:
  case DeoptValueEncoding::StackType:
  case DeoptValueEncoding::MonitorType:
  case DeoptValueEncoding::ScalarValueType:
  case DeoptValueEncoding::OrigPcSlotType:
  case DeoptValueEncoding::MethodType:
  case DeoptValueEncoding::NarrowOopMarkerType:
  case DeoptValueEncoding::VORefLocalType:
  case DeoptValueEncoding::VORefStackType:
    ValueType = static_cast<DeoptValueEncoding::DeoptValueType>(RawValueType);
    break;
  default:
    return std::nullopt;
  }

  uint16_t RawBasicType = static_cast<uint16_t>(Raw & 0xffff);
  HotspotBasicType BasicType;
  switch (RawBasicType) {
  case T_BOOLEAN:
  case T_CHAR:
  case T_FLOAT:
  case T_DOUBLE:
  case T_BYTE:
  case T_SHORT:
  case T_INT:
  case T_LONG:
  case T_OBJECT:
  case T_ARRAY:
  case T_VOID:
  case T_ADDRESS:
  case T_NARROWOOP:
  case T_METADATA:
  case T_NARROWKLASS:
  case T_CONFLICT:
  case T_ILLEGAL:
    BasicType = static_cast<HotspotBasicType>(RawBasicType);
    break;
  default:
    return std::nullopt;
  }

  return CheckedDeoptValueEncoding{
      static_cast<int32_t>(static_cast<uint32_t>(Raw >> 32)), ValueType,
      BasicType};
}

namespace {

// Recursive-descent parser for the record grammar of Jeandle's "deopt"
// operand bundle. Wire layout:
//
//   [i64 should_reexecute]   production records only; hand-written tests
//                            omit it
//   root scope header        duplicated equal-i32 BCI pair
//   VO descriptor pool       zero or more descriptors, each: header
//                            encoding, i64 klass, i32 field count, then
//                            per-field encoding + value records
//   root scope body          locals, stack values, monitors, [original PC]
//   inlinee scopes           each: method marker pair, scope header, scope
//                            body; the innermost scope is LAST
//   narrow-oop tail          zero or more marker + narrow-oop pairs
//
// The parser enforces grammar order, record shapes, descriptor wire-ID
// uniqueness, and VO-reference well-formedness; it records every operand
// position as a semantic cell and builds the structural fingerprint used to
// detect later bundle edits. All failures are reported as data
// (DeoptBundleParseError); it never asserts, so it is safe on arbitrary IR.
class SemanticDeoptBundleParser {
public:
  explicit SemanticDeoptBundleParser(ArrayRef<Value *> Inputs)
      : Inputs(Inputs) {
    for (Value *Input : Inputs)
      Bundle.OriginalInputs.emplace_back(Input);
  }

  // Parse the whole bundle: root scope (header, VO descriptor pool, body),
  // then inlinee scopes (method marker, header, body each; innermost last),
  // then the narrow-oop tail, and finally the VO-reference validation.
  DeoptBundleParseResult parse() {
    ParsedDeoptScope Root;
    if (!parseScopeHeader(Root))
      return result();

    if (!parseRootPool())
      return result();
    if (!parseScopeBody(Root, /*IsRoot=*/true))
      return result();
    Bundle.Scopes.push_back(std::move(Root));

    while (Pos < Inputs.size()) {
      std::optional<CheckedDeoptValueEncoding> Encoding =
          decodeDeoptValueEncoding(Inputs[Pos]);
      if (!Encoding)
        return fail(DeoptBundleParseErrorCode::InvalidEncoding, Pos);
      if (Encoding->ValueType == DeoptValueEncoding::NarrowOopMarkerType)
        break;
      if (Encoding->ValueType != DeoptValueEncoding::MethodType)
        return fail(DeoptBundleParseErrorCode::InvalidScopeOrder, Pos);

      ParsedDeoptScope InlineScope;
      if (!parseMethodMarker(InlineScope) || !parseScopeHeader(InlineScope) ||
          !parseScopeBody(InlineScope, /*IsRoot=*/false))
        return result();
      Bundle.Scopes.push_back(std::move(InlineScope));
    }

    if (!parseNarrowOopTail() || !validateReferences())
      return result();
    return DeoptBundleParseResult{std::move(Bundle), {}};
  }

private:
  // Section ordering enforced within a scope body.
  enum class ScopePhase : uint8_t { Locals, Stack, Monitors, OrigPc };

  // Failure reporting: record the error and produce an empty result. The
  // parser stops at the first failure, so only one error is ever recorded.
  DeoptBundleParseResult fail(DeoptBundleParseErrorCode Code,
                              unsigned OperandIndex) {
    Error = {Code, OperandIndex};
    return result();
  }

  bool failBool(DeoptBundleParseErrorCode Code, unsigned OperandIndex) {
    Error = {Code, OperandIndex};
    return false;
  }

  DeoptBundleParseResult result() {
    return DeoptBundleParseResult{std::nullopt, Error};
  }

  static ConstantInt *getIntegerConstant(Value *V, unsigned BitWidth) {
    auto *CI = dyn_cast_or_null<ConstantInt>(V);
    return CI && CI->getType()->isIntegerTy(BitWidth) ? CI : nullptr;
  }

  // Record operand Index as a fingerprint cell and return its semantic
  // cell. Grammar constants (KeepConstant) contribute their exact bits to
  // the fingerprint; semantic values contribute only their type, so
  // legitimate RAUW does not register as staleness.
  DeoptSemanticCell recordCell(DeoptSemanticCellRole Role, unsigned Index,
                               bool KeepConstant) {
    DeoptStructuralCell Structural{Role, Index, Inputs[Index]->getType(),
                                   std::nullopt};
    if (KeepConstant)
      if (auto *CI = dyn_cast<ConstantInt>(Inputs[Index]))
        Structural.ConstantValue = CI->getZExtValue();
    Bundle.Fingerprint.Cells.push_back(Structural);
    return {Role, Index};
  }

  // Parse one scope header: the optional i64 should_reexecute slot followed
  // by the duplicated equal-i32 BCI pair that opens every scope.
  bool parseScopeHeader(ParsedDeoptScope &Scope) {
    if (Pos >= Inputs.size())
      return failBool(DeoptBundleParseErrorCode::InvalidScopeHeader, Pos);

    // Production records carry should_reexecute before the duplicated BCI.
    // Hand-written PEA tests intentionally use only the duplicated pair.
    if (Pos + 2 < Inputs.size()) {
      ConstantInt *Should = getIntegerConstant(Inputs[Pos], 64);
      ConstantInt *BCI0 = getIntegerConstant(Inputs[Pos + 1], 32);
      ConstantInt *BCI1 = getIntegerConstant(Inputs[Pos + 2], 32);
      if (Should && BCI0 && BCI1) {
        if (Should->getZExtValue() > 1)
          return failBool(DeoptBundleParseErrorCode::InvalidScopeHeader, Pos);
        Scope.ShouldReexecute = Should->getZExtValue();
        Scope.ShouldReexecuteCell =
            recordCell(DeoptSemanticCellRole::ShouldReexecute, Pos, true);
        ++Pos;
      }
    }

    if (Pos + 1 >= Inputs.size())
      return failBool(DeoptBundleParseErrorCode::InvalidScopeHeader, Pos);
    ConstantInt *BCI0 = getIntegerConstant(Inputs[Pos], 32);
    ConstantInt *BCI1 = getIntegerConstant(Inputs[Pos + 1], 32);
    if (!BCI0 || !BCI1)
      return failBool(DeoptBundleParseErrorCode::InvalidScopeHeader, Pos);
    if (BCI0->getValue() != BCI1->getValue())
      return failBool(DeoptBundleParseErrorCode::MismatchedBCI, Pos);

    Scope.BCI = static_cast<int32_t>(BCI0->getSExtValue());
    Scope.FirstBCICell = recordCell(DeoptSemanticCellRole::BCI, Pos, true);
    ++Pos;
    Scope.SecondBCICell = recordCell(DeoptSemanticCellRole::BCI, Pos, true);
    ++Pos;
    return true;
  }

  // Parse the root scope's VO descriptor pool: the run of ScalarValueType
  // descriptor records. Stops successfully at the first non-descriptor
  // operand, which begins the root scope body.
  bool parseRootPool() {
    while (Pos < Inputs.size()) {
      std::optional<CheckedDeoptValueEncoding> Encoding =
          decodeDeoptValueEncoding(Inputs[Pos]);
      if (!Encoding ||
          Encoding->ValueType != DeoptValueEncoding::ScalarValueType)
        return true;
      if (!parseDescriptor(*Encoding))
        return false;
    }
    return true;
  }

  // Parse one VO descriptor: the header encoding (ScalarValueType; index =
  // wire ID; basic type T_OBJECT or T_ARRAY), the nonzero i64 klass pointer,
  // the non-negative i32 field count, then that many (encoding, value)
  // field records. Field offsets must be unique within the descriptor. A
  // VORefLocalType field references another descriptor by wire ID and is
  // queued in References for the final dangling-reference check.
  bool parseDescriptor(const CheckedDeoptValueEncoding &Header) {
    unsigned HeaderIndex = Pos;
    if (Header.Index < 0 ||
        (Header.BasicType != T_OBJECT && Header.BasicType != T_ARRAY))
      return failBool(DeoptBundleParseErrorCode::InvalidEncoding, Pos);
    if (!DescriptorIDs.insert(Header.Index).second)
      return failBool(DeoptBundleParseErrorCode::DuplicateDescriptorID, Pos);
    if (Inputs.size() - Pos < 3)
      return failBool(DeoptBundleParseErrorCode::TruncatedRecord, Pos);

    ParsedDeoptDescriptor Descriptor;
    Descriptor.WireID = Header.Index;
    Descriptor.IsArray = Header.BasicType == T_ARRAY;
    Descriptor.HeaderCell =
        recordCell(DeoptSemanticCellRole::DescriptorHeader, Pos, true);
    ++Pos;

    ConstantInt *Klass = getIntegerConstant(Inputs[Pos], 64);
    if (!Klass || Klass->isZero())
      return failBool(DeoptBundleParseErrorCode::InvalidSemanticValue, Pos);
    Descriptor.Klass = Klass->getZExtValue();
    Descriptor.KlassCell =
        recordCell(DeoptSemanticCellRole::DescriptorKlass, Pos, true);
    ++Pos;

    ConstantInt *FieldCount = getIntegerConstant(Inputs[Pos], 32);
    if (!FieldCount || FieldCount->isNegative())
      return failBool(DeoptBundleParseErrorCode::InvalidSemanticValue, Pos);
    uint64_t Count = FieldCount->getZExtValue();
    Descriptor.FieldCountCell =
        recordCell(DeoptSemanticCellRole::DescriptorFieldCount, Pos, true);
    ++Pos;
    if (Count > (Inputs.size() - Pos) / 2)
      return failBool(DeoptBundleParseErrorCode::TruncatedRecord, HeaderIndex);

    // Field records: an encoding operand followed by a value operand. The
    // truncation check above guarantees Count records fit in the remaining
    // inputs; offsets must be unique within the descriptor.
    SmallSet<int32_t, 8> FieldOffsets;
    Descriptor.Fields.reserve(static_cast<unsigned>(Count));
    for (uint64_t I = 0; I < Count; ++I) {
      unsigned EncodingIndex = Pos;
      std::optional<CheckedDeoptValueEncoding> FieldEncoding =
          decodeDeoptValueEncoding(Inputs[Pos]);
      if (!FieldEncoding || FieldEncoding->Index < 0)
        return failBool(DeoptBundleParseErrorCode::InvalidEncoding, Pos);
      if (FieldEncoding->ValueType != DeoptValueEncoding::LocalType &&
          FieldEncoding->ValueType != DeoptValueEncoding::VORefLocalType)
        return failBool(DeoptBundleParseErrorCode::InvalidEncoding, Pos);
      if (!FieldOffsets.insert(FieldEncoding->Index).second)
        return failBool(DeoptBundleParseErrorCode::DuplicateFieldOffset, Pos);

      ParsedDeoptField Field;
      Field.Offset = FieldEncoding->Index;
      Field.Encoding = *FieldEncoding;
      Field.EncodingCell =
          recordCell(DeoptSemanticCellRole::DescriptorFieldEncoding, Pos, true);
      ++Pos;
      Field.ValueCell = {DeoptSemanticCellRole::DescriptorFieldValue, Pos};

      if (FieldEncoding->ValueType == DeoptValueEncoding::VORefLocalType) {
        // VO-reference field: the value operand is the wire ID of the
        // referenced descriptor, carried as an i32 constant.
        if (FieldEncoding->BasicType != T_OBJECT)
          return failBool(DeoptBundleParseErrorCode::InvalidEncoding,
                          EncodingIndex);
        std::optional<int32_t> Target = parseWireID(Inputs[Pos]);
        if (!Target)
          return failBool(DeoptBundleParseErrorCode::InvalidSemanticValue, Pos);
        Field.TargetWireID = *Target;
        References.push_back({*Target, Pos});
        recordCell(DeoptSemanticCellRole::DescriptorFieldValue, Pos, true);
      } else {
        // Scalar field: the value must match the encoding's basic type. A
        // T_ILLEGAL filler is a grammar constant (zero) and contributes its
        // exact bits to the fingerprint.
        if (!isValidScalarValue(FieldEncoding->BasicType, Inputs[Pos]))
          return failBool(DeoptBundleParseErrorCode::InvalidSemanticValue, Pos);
        recordCell(DeoptSemanticCellRole::DescriptorFieldValue, Pos,
                   FieldEncoding->BasicType == T_ILLEGAL);
      }
      ++Pos;
      Descriptor.Fields.push_back(std::move(Field));
    }
    Bundle.Descriptors.push_back(std::move(Descriptor));
    return true;
  }

  // Parse one scope body: locals, then stack values, then monitors, then
  // (at most once, root scope only) the original-PC marker. The phase
  // machine enforces that order: a record may continue the current phase or
  // advance it, never go back. MethodType (an inlinee scope follows) and
  // NarrowOopMarkerType (the tail follows) end the body; a ScalarValueType
  // descriptor here is an error, because descriptors live only in the root
  // pool.
  bool parseScopeBody(ParsedDeoptScope &Scope, bool IsRoot) {
    ScopePhase Phase = ScopePhase::Locals;
    // Next expected slot index within the locals and stack sections; scalar
    // records must carry consecutive indices (see parseScopeValue).
    int64_t NextLocalIndex = 0;
    int64_t NextStackIndex = 0;
    while (Pos < Inputs.size()) {
      std::optional<CheckedDeoptValueEncoding> Encoding =
          decodeDeoptValueEncoding(Inputs[Pos]);
      if (!Encoding)
        return failBool(DeoptBundleParseErrorCode::InvalidEncoding, Pos);

      switch (Encoding->ValueType) {
      case DeoptValueEncoding::MethodType:
      case DeoptValueEncoding::NarrowOopMarkerType:
        return true;
      case DeoptValueEncoding::ScalarValueType:
        return failBool(DeoptBundleParseErrorCode::DescriptorNotInRootPool,
                        Pos);
      case DeoptValueEncoding::LocalType:
      case DeoptValueEncoding::VORefLocalType:
        if (Phase != ScopePhase::Locals)
          return failBool(DeoptBundleParseErrorCode::InvalidScopeOrder, Pos);
        if (!parseScopeValue(Scope.Locals, *Encoding, NextLocalIndex))
          return false;
        break;
      case DeoptValueEncoding::StackType:
      case DeoptValueEncoding::VORefStackType:
        if (Phase > ScopePhase::Stack)
          return failBool(DeoptBundleParseErrorCode::InvalidScopeOrder, Pos);
        Phase = ScopePhase::Stack;
        if (!parseScopeValue(Scope.Stack, *Encoding, NextStackIndex))
          return false;
        break;
      case DeoptValueEncoding::MonitorType:
        if (Phase > ScopePhase::Monitors)
          return failBool(DeoptBundleParseErrorCode::InvalidScopeOrder, Pos);
        Phase = ScopePhase::Monitors;
        if (!parseMonitor(Scope, *Encoding))
          return false;
        break;
      case DeoptValueEncoding::OrigPcSlotType:
        if (!IsRoot || Scope.OrigPc || Phase == ScopePhase::OrigPc)
          return failBool(DeoptBundleParseErrorCode::InvalidOrigPc, Pos);
        Phase = ScopePhase::OrigPc;
        if (!parseOrigPc(Scope, *Encoding))
          return false;
        break;
      default:
        return failBool(DeoptBundleParseErrorCode::InvalidScopeOrder, Pos);
      }
    }
    return true;
  }

  // Parse one local or stack slot: an encoding operand followed by a value
  // operand. Scalar slots must carry consecutive slot indices starting at
  // NextSlotIndex, which advances by the slot width (long/double occupy two
  // frame slots). A VORef slot instead names its descriptor's wire ID in
  // the encoding index, and the value operand repeats that wire ID as an
  // i32 constant (queued in References for the dangling-reference check).
  bool parseScopeValue(SmallVectorImpl<ParsedDeoptScopeValue> &Values,
                       const CheckedDeoptValueEncoding &Encoding,
                       int64_t &NextSlotIndex) {
    if (Inputs.size() - Pos < 2)
      return failBool(DeoptBundleParseErrorCode::TruncatedRecord, Pos);

    bool IsVORef = Encoding.ValueType == DeoptValueEncoding::VORefLocalType ||
                   Encoding.ValueType == DeoptValueEncoding::VORefStackType;
    if (!IsVORef && (Encoding.Index < 0 || Encoding.Index != NextSlotIndex))
      return failBool(DeoptBundleParseErrorCode::InvalidEncoding, Pos);
    if (IsVORef && (Encoding.Index < 0 || Encoding.BasicType != T_OBJECT))
      return failBool(DeoptBundleParseErrorCode::InvalidEncoding, Pos);

    ParsedDeoptScopeValue Parsed;
    Parsed.PhysicalSlot = static_cast<unsigned>(NextSlotIndex);
    Parsed.SlotWidth = IsVORef || !isDoubleWordType(Encoding.BasicType) ? 1 : 2;
    Parsed.Encoding = Encoding;
    Parsed.EncodingCell =
        recordCell(DeoptSemanticCellRole::ScopeValueEncoding, Pos, true);
    ++Pos;
    Parsed.ValueCell = {DeoptSemanticCellRole::ScopeValue, Pos};
    if (IsVORef) {
      std::optional<int32_t> Target = parseWireID(Inputs[Pos]);
      if (!Target || *Target != Encoding.Index)
        return failBool(DeoptBundleParseErrorCode::InvalidSemanticValue, Pos);
      Parsed.TargetWireID = *Target;
      References.push_back({*Target, Pos});
      recordCell(DeoptSemanticCellRole::ScopeValue, Pos, true);
    } else {
      if (!isValidScalarValue(Encoding.BasicType, Inputs[Pos]))
        return failBool(DeoptBundleParseErrorCode::InvalidSemanticValue, Pos);
      recordCell(DeoptSemanticCellRole::ScopeValue, Pos,
                 Encoding.BasicType == T_ILLEGAL);
    }
    ++Pos;
    NextSlotIndex += Parsed.SlotWidth;
    Values.push_back(std::move(Parsed));
    return true;
  }

  // Parse one monitor record: encoding, owner, lock. The encoding index
  // distinguishes an eliminated monitor (1), whose owner operand is the
  // wire ID of the owner VO's descriptor, from a surviving monitor (0),
  // whose owner operand is a wide oop. The lock operand is always an
  // addrspace(0) pointer.
  bool parseMonitor(ParsedDeoptScope &Scope,
                    const CheckedDeoptValueEncoding &Encoding) {
    if (Inputs.size() - Pos < 3)
      return failBool(DeoptBundleParseErrorCode::TruncatedRecord, Pos);
    if ((Encoding.Index != 0 && Encoding.Index != 1) ||
        Encoding.BasicType != T_OBJECT)
      return failBool(DeoptBundleParseErrorCode::InvalidMonitor, Pos);

    ParsedDeoptMonitor Monitor;
    Monitor.Encoding = Encoding;
    Monitor.Eliminated = Encoding.Index == 1;
    Monitor.EncodingCell =
        recordCell(DeoptSemanticCellRole::MonitorEncoding, Pos, true);
    ++Pos;
    Monitor.OwnerCell = {DeoptSemanticCellRole::MonitorOwner, Pos};
    if (Monitor.Eliminated) {
      std::optional<int32_t> Owner = parseWireID(Inputs[Pos]);
      if (!Owner)
        return failBool(DeoptBundleParseErrorCode::InvalidMonitor, Pos);
      Monitor.OwnerWireID = *Owner;
      References.push_back({*Owner, Pos});
      recordCell(DeoptSemanticCellRole::MonitorOwner, Pos, true);
    } else {
      if (!isValidWideOop(Inputs[Pos]))
        return failBool(DeoptBundleParseErrorCode::InvalidMonitor, Pos);
      recordCell(DeoptSemanticCellRole::MonitorOwner, Pos, false);
    }
    ++Pos;
    Monitor.LockCell = {DeoptSemanticCellRole::MonitorLock, Pos};
    auto *LockTy = dyn_cast<PointerType>(Inputs[Pos]->getType());
    if (!LockTy || LockTy->getAddressSpace() != 0)
      return failBool(DeoptBundleParseErrorCode::InvalidMonitor, Pos);
    recordCell(DeoptSemanticCellRole::MonitorLock, Pos, false);
    ++Pos;
    Scope.Monitors.push_back(std::move(Monitor));
    return true;
  }

  // Parse the root scope's original-PC marker: an OrigPcSlotType encoding
  // (index 0, basic type T_ADDRESS) followed by the PC as an addrspace(0)
  // pointer.
  bool parseOrigPc(ParsedDeoptScope &Scope,
                   const CheckedDeoptValueEncoding &Encoding) {
    if (Inputs.size() - Pos < 2)
      return failBool(DeoptBundleParseErrorCode::TruncatedRecord, Pos);
    if (Encoding.Index != 0 || Encoding.BasicType != T_ADDRESS)
      return failBool(DeoptBundleParseErrorCode::InvalidOrigPc, Pos);
    ParsedDeoptMarker Marker;
    Marker.Encoding = Encoding;
    Marker.EncodingCell =
        recordCell(DeoptSemanticCellRole::OrigPcEncoding, Pos, true);
    ++Pos;
    auto *OrigPcTy = dyn_cast<PointerType>(Inputs[Pos]->getType());
    if (!OrigPcTy || OrigPcTy->getAddressSpace() != 0)
      return failBool(DeoptBundleParseErrorCode::InvalidOrigPc, Pos);
    Marker.ValueCell =
        recordCell(DeoptSemanticCellRole::OrigPcValue, Pos, false);
    ++Pos;
    Scope.OrigPc = Marker;
    return true;
  }

  // Parse an inlinee scope's method marker: a MethodType encoding (index 0,
  // basic type T_METADATA) followed by the inlinee's MethodType pointer as
  // a nonzero i64.
  bool parseMethodMarker(ParsedDeoptScope &Scope) {
    if (Inputs.size() - Pos < 2)
      return failBool(DeoptBundleParseErrorCode::TruncatedRecord, Pos);
    std::optional<CheckedDeoptValueEncoding> Encoding =
        decodeDeoptValueEncoding(Inputs[Pos]);
    if (!Encoding || Encoding->ValueType != DeoptValueEncoding::MethodType ||
        Encoding->Index != 0 || Encoding->BasicType != T_METADATA)
      return failBool(DeoptBundleParseErrorCode::InvalidMethodMarker, Pos);

    ParsedDeoptMethod Method;
    Method.EncodingCell =
        recordCell(DeoptSemanticCellRole::MethodEncoding, Pos, true);
    ++Pos;
    ConstantInt *MethodValue = getIntegerConstant(Inputs[Pos], 64);
    if (!MethodValue || MethodValue->isZero())
      return failBool(DeoptBundleParseErrorCode::InvalidMethodMarker, Pos);
    Method.Method = MethodValue->getZExtValue();
    Method.ValueCell =
        recordCell(DeoptSemanticCellRole::MethodValue, Pos, true);
    ++Pos;
    Scope.Method = Method;
    return true;
  }

  // Parse the narrow-oop tail, which runs to the end of the inputs: zero or
  // more records of a NarrowOopMarkerType encoding (index 0, basic type
  // T_NARROWOOP) followed by a narrow oop (NarrowOopAddrSpace pointer).
  bool parseNarrowOopTail() {
    while (Pos < Inputs.size()) {
      if (Inputs.size() - Pos < 2)
        return failBool(DeoptBundleParseErrorCode::TruncatedRecord, Pos);
      std::optional<CheckedDeoptValueEncoding> Encoding =
          decodeDeoptValueEncoding(Inputs[Pos]);
      if (!Encoding ||
          Encoding->ValueType != DeoptValueEncoding::NarrowOopMarkerType ||
          Encoding->Index != 0 || Encoding->BasicType != T_NARROWOOP)
        return failBool(DeoptBundleParseErrorCode::InvalidNarrowOopMarker, Pos);

      ParsedDeoptMarker Marker;
      Marker.Encoding = *Encoding;
      Marker.EncodingCell =
          recordCell(DeoptSemanticCellRole::NarrowOopEncoding, Pos, true);
      ++Pos;
      auto *NarrowTy = dyn_cast<PointerType>(Inputs[Pos]->getType());
      if (!NarrowTy ||
          NarrowTy->getAddressSpace() != AddrSpace::NarrowOopAddrSpace)
        return failBool(DeoptBundleParseErrorCode::InvalidNarrowOopMarker, Pos);
      Marker.ValueCell =
          recordCell(DeoptSemanticCellRole::NarrowOopValue, Pos, false);
      ++Pos;
      Bundle.NarrowOopMarkers.push_back(Marker);
    }
    return true;
  }

  // Every VO reference collected during the parse must name a descriptor
  // present in the root pool.
  bool validateReferences() {
    for (const auto &[WireID, OperandIndex] : References)
      if (!DescriptorIDs.contains(WireID))
        return failBool(DeoptBundleParseErrorCode::DanglingVORef, OperandIndex);
    return true;
  }

  // A wire ID operand is a non-negative i32 constant.
  static std::optional<int32_t> parseWireID(Value *V) {
    ConstantInt *CI = getIntegerConstant(V, 32);
    if (!CI || CI->isNegative())
      return std::nullopt;
    return static_cast<int32_t>(CI->getZExtValue());
  }

  // A wide oop is a JavaHeapAddrSpace pointer; the only permitted constant
  // is null.
  static bool isValidWideOop(Value *V) {
    auto *Ty = dyn_cast<PointerType>(V->getType());
    if (!Ty || Ty->getAddressSpace() != AddrSpace::JavaHeapAddrSpace)
      return false;
    return !isa<Constant>(V) || isa<ConstantPointerNull>(V);
  }

  // Type-check a scalar value operand against its declared basic type.
  // T_ILLEGAL marks a dead slot and must be a zero constant.
  static bool isValidScalarValue(HotspotBasicType BasicType, Value *V) {
    Type *Ty = V->getType();
    switch (BasicType) {
    case T_INT:
      return Ty->isIntegerTy() && Ty->getIntegerBitWidth() <= 32;
    case T_LONG:
      return Ty->isIntegerTy(64);
    case T_FLOAT:
      return Ty->isFloatTy();
    case T_DOUBLE:
      return Ty->isDoubleTy();
    case T_OBJECT:
      return isValidWideOop(V);
    case T_ILLEGAL: {
      auto *CI = dyn_cast<ConstantInt>(V);
      return CI && CI->isZero();
    }
    default:
      return false;
    }
  }

  ArrayRef<Value *> Inputs;           // Bundle inputs, in wire order.
  unsigned Pos = 0;                   // Index of the next unparsed input.
  ParsedDeoptBundle Bundle;           // Parse tree under construction.
  DeoptBundleParseError Error;        // The failure that ended the parse.
  SmallSet<int32_t, 8> DescriptorIDs; // Descriptor wire IDs seen so far.
  // (WireID, operand index) of every VO reference, validated against
  // DescriptorIDs after the whole bundle is parsed.
  SmallVector<std::pair<int32_t, unsigned>, 8> References;
};

} // namespace

DeoptBundleParseResult parseDeoptBundleInputs(ArrayRef<Value *> Inputs) {
  return SemanticDeoptBundleParser(Inputs).parse();
}

DeoptBundleParseResult parseDeoptBundle(const CallBase &CB) {
  auto Deopt = CB.getOperandBundle(LLVMContext::OB_deopt);
  if (!Deopt)
    return {std::nullopt, {DeoptBundleParseErrorCode::MissingBundle, 0}};
  SmallVector<Value *, 16> Inputs;
  Inputs.reserve(Deopt->Inputs.size());
  for (const Use &Input : Deopt->Inputs)
    Inputs.push_back(Input.get());
  return parseDeoptBundleInputs(Inputs);
}

// Per-operand staleness check of a parsed bundle against a bundle's current
// inputs. An operand matches iff (a) it is the very SSA value recorded at
// parse time (the tracking handles follow legitimate RAUW, so a RAUW'd
// value still matches), (b) its LLVM type is unchanged, and (c) for
// grammar-constant cells its constant bits are exactly equal. Any mismatch
// means the bundle was structurally edited since the parse.
static bool matchesFingerprint(const ParsedDeoptBundle &Bundle,
                               ArrayRef<Value *> Inputs) {
  if (Inputs.size() != Bundle.OriginalInputs.size() ||
      Inputs.size() != Bundle.Fingerprint.Cells.size())
    return false;
  for (unsigned I = 0; I < Inputs.size(); ++I) {
    Value *Tracked = Bundle.OriginalInputs[I];
    Value *Input = Inputs[I];
    const DeoptStructuralCell &Cell = Bundle.Fingerprint.Cells[I];
    if (!Tracked || Input != Tracked || Cell.OperandIndex != I ||
        Cell.OperandType != Input->getType())
      return false;
    if (Cell.ConstantValue) {
      auto *CI = dyn_cast<ConstantInt>(Input);
      if (!CI || CI->getZExtValue() != *Cell.ConstantValue)
        return false;
    }
  }
  return true;
}

bool matchesParsedDeoptBundle(const ParsedDeoptBundle &Bundle,
                              const CallBase &CB) {
  auto Deopt = CB.getOperandBundle(LLVMContext::OB_deopt);
  if (!Deopt)
    return false;
  SmallVector<Value *, 16> Inputs;
  Inputs.reserve(Deopt->Inputs.size());
  for (const Use &Input : Deopt->Inputs)
    Inputs.push_back(Input.get());
  return matchesFingerprint(Bundle, Inputs);
}

bool copyParsedDeoptBundleInputs(const ParsedDeoptBundle &Bundle,
                                 SmallVectorImpl<Value *> &Out) {
  SmallVector<Value *, 16> Inputs;
  Inputs.reserve(Bundle.OriginalInputs.size());
  for (const WeakTrackingVH &Input : Bundle.OriginalInputs) {
    Value *V = Input;
    if (!V)
      return false;
    Inputs.push_back(V);
  }
  if (!matchesFingerprint(Bundle, Inputs))
    return false;
  Out.append(Inputs.begin(), Inputs.end());
  return true;
}

std::optional<unsigned>
findInnermostDeoptScopeBCIPairStart(const CallBase &CB) {
  auto Deopt = CB.getOperandBundle(LLVMContext::OB_deopt);
  if (!Deopt)
    return std::nullopt;
  for (unsigned I = Deopt->Inputs.size(); I > 1; --I) {
    auto *BCI0 = dyn_cast<ConstantInt>(Deopt->Inputs[I - 2].get());
    auto *BCI1 = dyn_cast<ConstantInt>(Deopt->Inputs[I - 1].get());
    if (!BCI0 || !BCI1 || !BCI0->getType()->isIntegerTy(32) ||
        !BCI1->getType()->isIntegerTy(32))
      continue;
    if (BCI0->getSExtValue() != BCI1->getSExtValue())
      return std::nullopt; // malformed pair — scope boundaries unknown.
    return I - 2;
  }
  return std::nullopt;
}

std::optional<unsigned> findFirstDeoptScopeBCIPairStart(const CallBase &CB) {
  auto Deopt = CB.getOperandBundle(LLVMContext::OB_deopt);
  if (!Deopt)
    return std::nullopt;
  for (unsigned I = 2; I <= Deopt->Inputs.size(); ++I) {
    auto *BCI0 = dyn_cast<ConstantInt>(Deopt->Inputs[I - 2].get());
    auto *BCI1 = dyn_cast<ConstantInt>(Deopt->Inputs[I - 1].get());
    if (!BCI0 || !BCI1 || !BCI0->getType()->isIntegerTy(32) ||
        !BCI1->getType()->isIntegerTy(32))
      continue;
    if (BCI0->getSExtValue() != BCI1->getSExtValue())
      return std::nullopt; // malformed pair — scope boundaries unknown.
    return I - 2;
  }
  return std::nullopt;
}

} // namespace llvm::jeandle::pea
