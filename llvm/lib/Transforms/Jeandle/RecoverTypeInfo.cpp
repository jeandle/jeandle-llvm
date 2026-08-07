//===- RecoverTypeInfo.cpp - Recover dropped !java-klass metadata ---------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This pass recovers !java-klass / !java-klass-exact metadata on oop-typed
// field loads that was dropped by earlier optimizations (EarlyCSE / InstCombine
// load CSE only preserve LLVM's built-in metadata kinds; "java-klass" is a
// custom kind and falls into the `default:` stripping branch of
// combineMetadata / copyMetadataForLoad).
//
// For a field load whose pointer is (base + constant offset), the declared
// field type is recomputed as GetFieldType(baseKlass, offset). baseKlass itself
// may come from:
//   * a java-klass attribute on an argument or call return (robust, survives
//     CSE),
//   * surviving !java-klass metadata on another load,
//   * a constant oop handle (GetOopKlass),
//   * another recovered field load (arbitrary chains).
//
// The analysis is a monotone fixpoint over a three-state lattice. See the
// header for the high-level guarantees; the invariants that make the fixpoint
// converge are documented inline below.
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/RecoverTypeInfo.h"
#include "llvm/ADT/APInt.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/Statistic.h"
#include "llvm/IR/Attributes.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/InstrTypes.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Jeandle/JeandleUtils.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Operator.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Debug.h"

#include <climits>
#include <optional>
#include <utility>

#define DEBUG_TYPE "recover-type-info"

using namespace llvm;

using llvm::jeandle::getOopHandleId;
using llvm::jeandle::isJavaOopType;
using llvm::jeandle::isRootJavaMethodFunction;

STATISTIC(NumRecovered, "Number of field loads with recovered java-klass");

// Hidden test hook: when set (via -XX:JeandleLLVMOptions=--jeandle-disable-
// recover-type-info), RecoverTypeInfo becomes a no-op, so the
// !java-klass metadata stripped by load CSE (EarlyCSE/InstCombine) is NOT
// re-attached. Downstream consumers that learn a loaded oop's klass only from
// that metadata (notably CHADevirtualization, see CHADevirtualization.cpp:115)
// then cannot resolve the receiver type and bail — used by the jtreg test
// TestRecoverTypeInfoEnablesChaDevirt to prove RecoverTypeInfo is a
// prerequisite for CHA devirtualization of field-load receivers.
static cl::opt<bool> DisableRecoverTypeInfo(
    "jeandle-disable-recover-type-info", cl::init(false), cl::Hidden,
    cl::desc("Skip RecoverTypeInfo (do not re-attach !java-klass metadata). "
             "Test hook for proving downstream passes depend on recovered "
             "type metadata; not for production use."));

namespace {

// =============================================================================
// Lattice
// =============================================================================
//
// Per oop-typed value:
//   Top     — not yet resolved (only forwarders and field loads start here).
//             Acts as the identity element of meet, so an unresolved loop
//             back-edge does not poison a PHI.
//   Known   — the value is a non-null oop of klass `Klass` (Exact: not a
//             subclass).
//   Bottom  — provably unknowable (opaque producer: call without java-klass,
//             a load from non-Java-heap storage, an interface-typed field, or
//             a field that does not exist at the given offset). Kills positive
//             knowledge under meet.
//
// The lattice is ordered Top > Known{K} > Known{parent(K)} > ... > Bottom, so
// every transition during the fixpoint is a descent:
//   * seeds (attributes / surviving metadata / constant oop) are fixed;
//   * a forwarder descends as its operands descend;
//   * a field load descends as its base widens (the field may disappear at an
//     ancestor klass, taking the load Known -> Bottom);
//   * Bottom is terminal.
// Monotone descent over a finite lattice terminates.
struct Lattice {
  enum class Kind : uint8_t { Top, Known, Bottom };
  Kind K = Kind::Top;
  uintptr_t Klass = 0;
  bool Exact = false;

  static Lattice top() { return {Kind::Top, 0, false}; }
  static Lattice bottom() { return {Kind::Bottom, 0, false}; }
  static Lattice known(uintptr_t Klass, bool Exact) {
    return {Kind::Known, Klass, Exact};
  }

  bool isTop() const { return K == Kind::Top; }
  bool isKnown() const { return K == Kind::Known; }
  bool isBottom() const { return K == Kind::Bottom; }

  bool operator==(const Lattice &O) const {
    return K == O.K && Klass == O.Klass && Exact == O.Exact;
  }
  bool operator!=(const Lattice &O) const { return !(*this == O); }
};

// =============================================================================
// Forwarders — oop-typed instructions whose klass is determined by their
// operands (so they start at Top and are pulled down by the worklist). Loads
// are handled separately (as seeds or field loads), and non-zero-offset GEPs
// are NOT forwarders (they produce interior pointers, not object references).
// =============================================================================
bool isForwarder(Instruction &I) {
  if (!isJavaOopType(I.getType()))
    return false;
  if (isa<PHINode>(I) || isa<SelectInst>(I) || isa<BitCastInst>(I) ||
      isa<AddrSpaceCastInst>(I) || isa<FreezeInst>(I))
    return true;
  if (auto *GEP = dyn_cast<GetElementPtrInst>(&I))
    return GEP->hasAllZeroIndices();
  if (auto *II = dyn_cast<IntrinsicInst>(&I))
    return II->getIntrinsicID() == Intrinsic::launder_invariant_group ||
           II->getIntrinsicID() == Intrinsic::strip_invariant_group;
  return false;
}

} // namespace

PreservedAnalyses RecoverTypeInfo::run(Function &F,
                                       FunctionAnalysisManager &FAM) {
  Module *M = F.getParent();
  if (!M->getNamedMetadata(jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();

  // Test hook (see DisableRecoverTypeInfo above): become a no-op so the
  // stripped !java-klass metadata is not re-attached, exercising downstream
  // passes without recovered type metadata.
  if (DisableRecoverTypeInfo)
    return PreservedAnalyses::all();

  // RecoverTypeInfo is intra-procedural and only the root Java method is ever
  // emitted; running it on the template JavaOp helpers and inlined
  // available_externally callees is wasted compile time with no effect on the
  // emitted object. Skip any function that is not the root Java method.
  if (!isRootJavaMethodFunction(F))
    return PreservedAnalyses::all();

  const jeandle::VMCallbacks *CB = jeandle::getVMCallbacks();
  assert(CB && CB->GetFieldType && CB->GetOopKlass && CB->IsEffectivelyFinal &&
         CB->IsUnverifiedInterface && CB->GetCommonSuperKlass &&
         "VMCallbacks must be set");

  const DataLayout &DL = M->getDataLayout();
  LLVMContext &Ctx = F.getContext();

  // ---------------------------------------------------------------------------
  // Memoized VM queries. Each distinct (klass, offset) / klass / klass-pair is
  // queried at most once, which keeps the recorded callback log minimal. These
  // caches are keyed by the callback arguments themselves and are never
  // iterated, so their key type plays no role in VMCallback replay determinism.
  // ---------------------------------------------------------------------------
  DenseMap<std::pair<uintptr_t, int>, uintptr_t> FieldTypeCache;
  DenseMap<int, uintptr_t> OopKlassCache;
  DenseMap<uintptr_t, bool> EffFinalCache;
  DenseMap<uintptr_t, bool> UnvIfaceCache;
  DenseMap<std::pair<uintptr_t, uintptr_t>, uintptr_t> LcaCache;

  auto getField = [&](uintptr_t Klass, int Offset) -> uintptr_t {
    auto Key = std::make_pair(Klass, Offset);
    auto It = FieldTypeCache.find(Key);
    if (It != FieldTypeCache.end())
      return It->second;
    uintptr_t R = CB->GetFieldType(Klass, Offset);
    FieldTypeCache[Key] = R;
    return R;
  };
  auto getOopKlass = [&](int Id) -> uintptr_t {
    auto It = OopKlassCache.find(Id);
    if (It != OopKlassCache.end())
      return It->second;
    uintptr_t R = CB->GetOopKlass(Id);
    OopKlassCache[Id] = R;
    return R;
  };
  auto isEffFinal = [&](uintptr_t Klass) -> bool {
    auto It = EffFinalCache.find(Klass);
    if (It != EffFinalCache.end())
      return It->second;
    bool R = CB->IsEffectivelyFinal(Klass);
    EffFinalCache[Klass] = R;
    return R;
  };
  auto isUnvIface = [&](uintptr_t Klass) -> bool {
    auto It = UnvIfaceCache.find(Klass);
    if (It != UnvIfaceCache.end())
      return It->second;
    bool R = CB->IsUnverifiedInterface(Klass);
    UnvIfaceCache[Klass] = R;
    return R;
  };
  auto lca = [&](uintptr_t A, uintptr_t B) -> uintptr_t {
    if (A == 0 || B == 0)
      return 0;
    if (A == B)
      return A;
    auto Key = std::make_pair(std::min(A, B), std::max(A, B));
    auto It = LcaCache.find(Key);
    if (It != LcaCache.end())
      return It->second;
    uintptr_t R = CB->GetCommonSuperKlass(A, B);
    LcaCache[Key] = R;
    return R;
  };

  // meet = typeUnion semantics: Top is identity, Bottom kills, Known joins to
  // LCA (Bottom if the two klasses have no common ancestor).
  auto meet = [&](const Lattice &A, const Lattice &B) -> Lattice {
    if (A.isTop())
      return B;
    if (B.isTop())
      return A;
    if (A.isBottom() || B.isBottom())
      return Lattice::bottom();
    if (A.Klass == B.Klass)
      return Lattice::known(A.Klass, A.Exact && B.Exact);
    uintptr_t L = lca(A.Klass, B.Klass);
    if (L == 0)
      return Lattice::bottom();
    return Lattice::known(L, false);
  };

  // ---------------------------------------------------------------------------
  // Seed readers
  // ---------------------------------------------------------------------------

  // Parse a "java-klass" attribute string (decimal klass pointer) plus the
  // optional "java-klass-exact" flag. Returns Bottom if absent/malformed.
  auto klassFromAttr = [&](const AttributeList &AL, unsigned Index) -> Lattice {
    if (!AL.hasAttributeAtIndex(Index, jeandle::Attribute::JavaKlass))
      return Lattice::bottom();
    StringRef S = AL.getAttributeAtIndex(Index, jeandle::Attribute::JavaKlass)
                      .getValueAsString();
    uintptr_t Klass = 0;
    if (S.getAsInteger(10, Klass) || Klass == 0)
      return Lattice::bottom();
    bool Exact =
        AL.hasAttributeAtIndex(Index, jeandle::Attribute::JavaKlassExact);
    return Lattice::known(Klass, Exact);
  };

  // Parse existing !java-klass metadata (same shape getBaseJavaType reads).
  // Returns Bottom if absent/malformed.
  auto klassFromMetadata = [&](LoadInst &LI) -> Lattice {
    MDNode *MD = LI.getMetadata(jeandle::Metadata::JavaKlass);
    if (!MD || MD->getNumOperands() < 1)
      return Lattice::bottom();
    auto *CMD = dyn_cast<ConstantAsMetadata>(MD->getOperand(0));
    if (!CMD)
      return Lattice::bottom();
    auto *CI = dyn_cast<ConstantInt>(CMD->getValue());
    if (!CI)
      return Lattice::bottom();
    uintptr_t Klass = CI->getZExtValue();
    if (Klass == 0)
      return Lattice::bottom();
    bool Exact = LI.getMetadata(jeandle::Metadata::JavaKlassExact) != nullptr;
    return Lattice::known(Klass, Exact);
  };

  // Strip a load pointer to (base, constant offset). Returns nullopt offset if
  // the offset does not fit in an int (e.g. huge/variable composite that
  // accumulated past int range). Uses stripAndAccumulateConstantOffsets so the
  // base is reached across nested constant GEPs, bitcasts, addrspacecasts and
  // invariant-group intrinsics.
  auto stripBaseOffset =
      [&](Value *Ptr) -> std::pair<Value *, std::optional<int>> {
    unsigned IdxBits = DL.getIndexTypeSizeInBits(Ptr->getType());
    APInt Off(IdxBits, 0, /*isSigned=*/true);
    Value *Base = Ptr->stripAndAccumulateConstantOffsets(
        DL, Off, /*AllowNonInbounds=*/true, /*AllowInvariantGroup=*/true);
    if (!Off.isSignedIntN(sizeof(int) * CHAR_BIT))
      return {Base, std::nullopt};
    return {Base, static_cast<int>(Off.getSExtValue())};
  };

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  DenseMap<Value *, Lattice> States;
  // Stripped (base, offset) per tracked field load.
  DenseMap<LoadInst *, std::pair<Value *, int>> FieldLoadBaseOff;

  auto getLattice = [&](Value *V) -> Lattice {
    auto It = States.find(V);
    if (It != States.end())
      return It->second;
    // Anything not tracked (Constants such as null, non-oop values, untracked
    // globals) is an opaque producer of unknown type.
    return Lattice::bottom();
  };

  auto seed = [&](Value *V, Lattice L) { States[V] = L; };

  // ---------------------------------------------------------------------------
  // Seed pass
  // ---------------------------------------------------------------------------

  // Oop-typed arguments.
  for (Argument &Arg : F.args()) {
    if (!isJavaOopType(Arg.getType()))
      continue;
    seed(&Arg, klassFromAttr(Arg.getParent()->getAttributes(),
                             Arg.getArgNo() + AttributeList::FirstArgIndex));
  }

  unsigned OopInstCount = 0;
  for (BasicBlock &BB : F) {
    for (Instruction &I : BB) {
      if (!isJavaOopType(I.getType()))
        continue;
      ++OopInstCount;

      // Call / invoke with java-klass return attribute.
      if (isa<CallBase>(&I)) {
        auto *CB2 = cast<CallBase>(&I);
        seed(&I,
             klassFromAttr(CB2->getAttributes(), AttributeList::ReturnIndex));
        continue;
      }

      // Loads: surviving metadata seed, constant-oop-handle seed, or a
      // recoverable field load.
      if (auto *LI = dyn_cast<LoadInst>(&I)) {
        if (Lattice L = klassFromMetadata(*LI); L.isKnown()) {
          seed(&I, L);
          continue;
        }
        if (std::optional<int> Id = getOopHandleId(LI->getPointerOperand())) {
          uintptr_t K = getOopKlass(*Id);
          seed(&I, K ? Lattice::known(K, /*Exact=*/true) : Lattice::bottom());
          continue;
        }
        // Field load. Recoverable only if its stripped base is a tracked oop
        // (Instruction/Argument) and the offset is a compile-time constant.
        auto [Base, OffOpt] = stripBaseOffset(LI->getPointerOperand());
        bool TrackedBase = (isa<Instruction>(Base) || isa<Argument>(Base)) &&
                           isJavaOopType(Base->getType()) && OffOpt.has_value();
        if (!TrackedBase) {
          // Loading from a stack slot / non-Java-heap address, or a
          // non-constant offset (e.g. array element with variable index): the
          // loaded klass is unknowable here.
          seed(&I, Lattice::bottom());
          continue;
        }
        int Off = *OffOpt;
        FieldLoadBaseOff[LI] = {Base, Off};
        States[&I] = Lattice::top(); // resolved during the fixpoint
        continue;
      }

      // Forwarder: starts Top, driven by operand changes.
      if (isForwarder(I)) {
        States[&I] = Lattice::top();
        continue;
      }

      // Opaque oop producer (call without java-klass, atomicrmw, non-zero GEP,
      // ...). Bottom is terminal and must propagate, so push it.
      seed(&I, Lattice::bottom());
    }
  }

  // ---------------------------------------------------------------------------
  // Transfer functions
  // ---------------------------------------------------------------------------
  auto transferForwarder = [&](Instruction &I) -> Lattice {
    if (auto *PN = dyn_cast<PHINode>(&I)) {
      // Self-referential and mutually-recursive back-edges are handled because
      // an unresolved PHI incoming is Top (identity); once it descends it only
      // feeds back a value that has already been accounted for.
      Lattice R = Lattice::top();
      for (Value *Inc : PN->incoming_values())
        R = meet(R, getLattice(Inc));
      return R;
    }
    if (auto *SI = dyn_cast<SelectInst>(&I))
      return meet(getLattice(SI->getTrueValue()),
                  getLattice(SI->getFalseValue()));
    if (isa<BitCastInst>(&I) || isa<AddrSpaceCastInst>(&I) ||
        isa<FreezeInst>(&I))
      return getLattice(I.getOperand(0));
    if (auto *GEP = dyn_cast<GetElementPtrInst>(&I)) {
      assert(GEP->hasAllZeroIndices() && "non-zero GEP is not a forwarder");
      return getLattice(GEP->getPointerOperand());
    }
    if (auto *II = dyn_cast<IntrinsicInst>(&I)) {
      assert((II->getIntrinsicID() == Intrinsic::launder_invariant_group ||
              II->getIntrinsicID() == Intrinsic::strip_invariant_group) &&
             "unexpected intrinsic forwarder");
      return getLattice(II->getArgOperand(0));
    }
    llvm_unreachable("transferForwarder on non-forwarder");
  };

  auto transferFieldLoad = [&](LoadInst *LI) -> Lattice {
    auto [Base, Off] = FieldLoadBaseOff[LI];
    Lattice BL = getLattice(Base);
    if (BL.isTop())
      return Lattice::top(); // base not resolved yet
    if (BL.isBottom())
      return Lattice::bottom(); // base is opaque
    uintptr_t FK = getField(BL.Klass, Off);
    if (FK == 0 || isUnvIface(FK))
      return Lattice::bottom(); // no such field, or interface-typed
                                // (unverifiable)
    return Lattice::known(FK, isEffFinal(FK));
  };

  // ---------------------------------------------------------------------------
  // Fixpoint over the dynamic values (forwarders and recoverable field loads),
  // iterated in program order until no lattice changes. Program order is an
  // ordered container — one of the SAFE iteration patterns in VMCallback.h — so
  // it is preserved across the record/replay boundary and the set of VM
  // callbacks issued here is reproducible between the recording JVM run and the
  // replay `opt` run. No snapshot is required: in-place (Gauss-Seidel) updates
  // only make each value descend faster, and the descending path each value
  // takes is still determined solely by program order, never by LLVM use-lists
  // or pointer addresses.
  //
  // Seeds and opaque values are fixed (set once in the seed pass) and are not
  // recomputed. Monotone descent over a finite lattice terminates; the cap is
  // a defensive backstop.
  // ---------------------------------------------------------------------------
  SmallVector<Instruction *, 64> Dynamic;
  // Dynamic values are exactly those seeded Top (forwarders and recoverable
  // field loads). Collect them in program order — NOT over the pointer-keyed
  // States DenseMap, whose iteration order is ASLR-dependent and therefore
  // unsafe under the replay model. Sweeping Dynamic in program order is what
  // keeps the in-place fixpoint (and its callback set) deterministic.
  // (getLattice returns Bottom for any value not in States, so non-tracked
  // instructions and non-oop values are skipped.)
  for (BasicBlock &BB : F)
    for (Instruction &I : BB)
      if (getLattice(&I).isTop())
        Dynamic.push_back(&I);

  unsigned Cap = 64 * (OopInstCount + 16) + 1024;
  unsigned Round = 0;
  bool SweepChanged = true;
  while (SweepChanged) {
    if (++Round > Cap) {
      LLVM_DEBUG(dbgs() << "recover-type-info: hit round cap, stopping early "
                           "(some types left unresolved)\n");
      break;
    }
    // Recompute every dynamic value in place; reading operands that were
    // updated earlier in this sweep only accelerates convergence.
    SweepChanged = false;
    for (Instruction *I : Dynamic) {
      Lattice New = isForwarder(*I) ? transferForwarder(*I)
                                    : transferFieldLoad(cast<LoadInst>(I));
      Lattice &Old = States[I];
      if (Old != New) {
        Old = New;
        SweepChanged = true;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Emit: attach metadata to resolved field loads that do not already have it.
  // ---------------------------------------------------------------------------
  bool Changed = false;
  for (BasicBlock &BB : F) {
    for (Instruction &I : BB) {
      auto *LI = dyn_cast<LoadInst>(&I);
      if (!LI || !isJavaOopType(LI->getType()))
        continue;
      if (LI->getMetadata(jeandle::Metadata::JavaKlass))
        continue; // already typed (frontend or a prior run) — leave untouched
      if (!FieldLoadBaseOff.count(LI))
        continue; // not a tracked field load (seed / opaque / non-constant
                  // base)
      Lattice L = getLattice(LI);
      if (!L.isKnown())
        continue;

      ConstantAsMetadata *KlassCMD = ConstantAsMetadata::get(
          ConstantInt::get(Type::getInt64Ty(Ctx), L.Klass));
      LI->setMetadata(jeandle::Metadata::JavaKlass,
                      MDNode::get(Ctx, {KlassCMD}));
      if (L.Exact)
        LI->setMetadata(jeandle::Metadata::JavaKlassExact,
                        MDNode::get(Ctx, {}));
      ++NumRecovered;
      Changed = true;
      LLVM_DEBUG(dbgs() << "recover-type-info: attached klass " << L.Klass
                        << (L.Exact ? " (exact)" : "") << " to " << *LI
                        << "\n");
    }
  }

  if (!Changed)
    return PreservedAnalyses::all();

  // Only metadata was added; CFG and instruction structure are unchanged.
  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>();
  return PA;
}
