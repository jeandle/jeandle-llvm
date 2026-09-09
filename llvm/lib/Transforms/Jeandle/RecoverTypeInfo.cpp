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
// This pass attaches !java-klass / !java-klass-exact metadata to oop-typed
// loads whose result klass can be proven:
//   * field loads that lost their metadata in earlier optimizations (EarlyCSE /
//     InstCombine load CSE only preserve LLVM's built-in metadata kinds;
//     "java-klass" is a custom kind and falls into the `default:` stripping
//     branch of combineMetadata / copyMetadataForLoad), and
//   * array element loads, which the frontend deliberately leaves untyped
//     (typing them during IR construction would query types of incomplete
//     PHIs; doing it here also enables context-sensitive precision).
//
// For a load whose base object's klass is known, the result klass is
// ArrayElementKlass(baseKlass) for an object-array base, or
// GetFieldType(baseKlass, offset) for an instance base at a constant offset.
// The base klass comes from two intersected sources:
//   * a fixpoint over a three-state lattice (Top / Known / Bottom)
//     seeded from java-klass attributes, surviving metadata and constant oop
//     handles, which propagates through forwarders (PHI / select / casts) and
//     already-recovered loads — this resolves arbitrary load chains and
//     loop-carried self-referential PHIs; and
//   * a context-sensitive getJavaType query on the base at the load's
//     position, which additionally exploits sharpening from jeandle
//     .check_instanceof edge guards (see JavaType.cpp's edge-semantics
//     engine). The pass mutates no IR until the emit phase, so this query is
//     constant and is computed once per load.
//
// See the header for the high-level guarantees; the invariants that make the
// fixpoint converge are documented inline below.
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/RecoverTypeInfo.h"
#include "llvm/ADT/APInt.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/Statistic.h"
#include "llvm/Analysis/LazyValueInfo.h"
#include "llvm/IR/Attributes.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/InstrTypes.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Jeandle/JavaType.h"
#include "llvm/IR/Jeandle/JeandleUtils.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Operator.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Debug.h"
#include "llvm/Transforms/Jeandle/JeandleTransformUtils.h"

#include <climits>
#include <optional>
#include <utility>

#define DEBUG_TYPE "recover-type-info"

using namespace llvm;

using llvm::jeandle::getOopHandleId;
using llvm::jeandle::isJavaOopType;
using llvm::jeandle::isRootJavaMethodFunction;

STATISTIC(NumRecovered, "Number of oop loads with recovered java-klass");

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
// almost every transition during the fixpoint is a descent:
//   * seeds (attributes / surviving metadata / constant oop) are fixed;
//   * a forwarder descends as its operands descend;
//   * a typed load descends as its base widens (the field may disappear at an
//     ancestor klass, taking the load Known -> Bottom);
//   * Bottom is terminal.
// The one exception is the context-query rescue: a value can ascend once from
// Top or Bottom to a Known the instanceof-derived facts prove (see
// transferTypedLoad and the PHI case of transferForwarder). Each value's
// trajectory is thus a klass-chain-bounded sequence of descents plus such
// one-shot rescues, so the fixpoint still converges; the round cap is a
// defensive backstop.
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
         CB->ArrayElementKlass && CB->IsSubtype && CB->IsInterface &&
         "VMCallbacks must be set");

  const DataLayout &DL = M->getDataLayout();
  LLVMContext &Ctx = F.getContext();

  // Used by the context-sensitive base-type queries below.
  DominatorTree &DT = FAM.getResult<DominatorTreeAnalysis>(F);
  // One LVI snapshot is valid for the whole pass: RecoverTypeInfo mutates no
  // IR until the metadata-only emit phase, and metadata is invisible to LVI.
  LazyValueInfo &LVI = FAM.getResult<LazyValueAnalysis>(F);
  LVINullEdgeOracle IsNullEdge{LVI};

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
  DenseMap<uintptr_t, uintptr_t> ArrayElemCache;
  auto arrayElemKlass = [&](uintptr_t Klass) -> uintptr_t {
    auto It = ArrayElemCache.find(Klass);
    if (It != ArrayElemCache.end())
      return It->second;
    uintptr_t R = CB->ArrayElementKlass(Klass);
    ArrayElemCache[Klass] = R;
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
  // A tracked typed load: an oop-typed load whose result klass can be derived
  // from the klass of the object being loaded from.
  struct LoadInfo {
    // The oop whose klass determines the load result: the stripped base when
    // the address is (base + constant offset), or the oop reached by peeling
    // variable-index GEPs when stripping stops at one.
    Value *QueryBase;
    // Constant byte offset; nullopt when the address contains variable-index
    // addressing (so there is no constant offset to consult GetFieldType
    // with). Whether such a load is really an array element load is NOT
    // decided here — constant-index aaloads have a constant offset too, and
    // the array-vs-field distinction is always made from the base klass in
    // transferTypedLoad.
    std::optional<int> Offset;
  };
  DenseMap<LoadInst *, LoadInfo> LoadInfos;

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
        // Typed load. Recoverable only if loading from a tracked oop
        // (Instruction/Argument). If offset stripping stops at a
        // variable-index GEP, peel such GEPs layer by layer to reach the oop
        // being addressed into (the frontend emits this shape for array
        // element addressing: ptradd(array, header) + GEP index, possibly
        // folded by later passes into variable-index GEPs on the array). The
        // loop terminates because each peel strictly follows the SSA def
        // chain towards its root. Note this address shape does not prove an
        // array element load — that distinction is made from the base klass
        // in transferTypedLoad.
        auto [Base, OffOpt] = stripBaseOffset(LI->getPointerOperand());
        Value *QueryBase = Base;
        bool HasVariableIndex = false;
        while (auto *GEP = dyn_cast<GetElementPtrInst>(QueryBase)) {
          if (GEP->hasAllConstantIndices())
            break;
          QueryBase = stripBaseOffset(GEP->getPointerOperand()).first;
          HasVariableIndex = true;
        }
        bool TrackedBase =
            (isa<Instruction>(QueryBase) || isa<Argument>(QueryBase)) &&
            isJavaOopType(QueryBase->getType()) &&
            (HasVariableIndex || OffOpt.has_value());
        if (!TrackedBase) {
          // Loading from a stack slot / non-Java-heap address, or not from a
          // tracked Java object: the loaded klass is unknowable here.
          seed(&I, Lattice::bottom());
          continue;
        }
        // For a variable-index address the accumulated constant part (if any)
        // is not a field offset, so only the constant-offset case keeps it.
        LoadInfos[LI] = {QueryBase, HasVariableIndex ? std::nullopt : OffOpt};
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
  // Context-sensitive type queries, computed lazily and memoized.
  //
  // getCtxType queries a tracked load's base with getJavaType in its
  // context-sensitive form: besides attributes, surviving metadata and
  // constant oop handles (all of which the lattice also uses), this exploits
  // sharpening from dominating jeandle.check_instanceof checks that constrain
  // the base at the load's position. The sharpening is sound here for the
  // same reason it is in TypeCheckElimination: the base oop is non-null at
  // the load, matching check_instanceof's non-null contract.
  //
  // Both queries' results are constant for the rest of the pass: the pass
  // mutates no IR until the emit phase, and they only read attributes,
  // metadata, the CFG and VM callbacks. Computing them lazily on first use is
  // therefore equivalent to an up-front pre-pass; first uses happen in
  // program order during the first fixpoint sweep (every tracked load and
  // forwarder is in Dynamic and its transfer runs unconditionally), which
  // keeps the issued VM callback set deterministic under record/replay. The
  // caches are only ever accessed by key — never iterated — so their
  // pointer-keyed iteration order plays no role.
  //
  // Completeness of getCtxType: a tracked load's QueryBase may itself be a
  // load whose metadata is only attached at the emit phase, so the cached
  // query cannot see that part of the base's type. That is exactly the part
  // the lattice carries: its seeds read the same sources the query does and
  // propagate them through forwarders and recovered loads, so once the
  // fixpoint settles, getLattice(QueryBase) is at least as strong as what
  // getBaseJavaType(QueryBase) would return after emit (strictly stronger
  // when per-incoming edge sharpening applies: getBaseJavaType's whole-PHI
  // union cannot see edge facts). The transfer intersects that lattice state
  // with the cached sharpening directly, so nothing is lost by caching.
  // ---------------------------------------------------------------------------
  DenseMap<LoadInst *, jeandle::JavaType> CtxCache;
  auto getCtxType = [&](LoadInst *LI) -> jeandle::JavaType {
    auto It = CtxCache.find(LI);
    if (It != CtxCache.end())
      return It->second;
    jeandle::JavaType T =
        jeandle::getJavaType(LoadInfos[LI].QueryBase, &DT, LI, IsNullEdge);
    return CtxCache.insert({LI, T}).first->second;
  };

  // Per-incoming edge sharpening for PHIs: the constraints that CFG edge
  // guards imply for the incoming value flowing along the edge (incoming
  // block -> PHI's block). This is the part a
  // whole-PHI context query cannot provide when any incoming's base type is
  // not yet visible (phiValueType bails on an unknown incoming): edge facts
  // depend only on the CFG and branch conditions, never on metadata, so they
  // are constant during the pass and can be intersected with the lattice's
  // evolving per-incoming states. Keyed by (PHINode*, incoming index) because
  // the same value may arrive along different edges with different facts.
  DenseMap<std::pair<PHINode *, unsigned>, jeandle::JavaType> EdgeSharpenCache;
  auto getEdgeSharpening = [&](PHINode *PN, unsigned Idx) -> jeandle::JavaType {
    auto Key = std::make_pair(PN, Idx);
    auto It = EdgeSharpenCache.find(Key);
    if (It != EdgeSharpenCache.end())
      return It->second;
    jeandle::JavaType S = jeandle::sharpen(
        PN->getIncomingValue(Idx), PN->getIncomingBlock(Idx)->getTerminator(),
        DT, PN->getParent(), IsNullEdge);
    return EdgeSharpenCache.insert({Key, S}).first->second;
  };

  // ---------------------------------------------------------------------------
  // Transfer functions
  // ---------------------------------------------------------------------------
  auto transferForwarder = [&](Instruction &I) -> Lattice {
    if (auto *PN = dyn_cast<PHINode>(&I)) {
      // Per-incoming: intersect the lattice state with the edge sharpening
      // (constant during the pass), then meet as usual. The edge sharpening
      // is what lets an instanceof on an incoming edge constrain the PHI even
      // while that incoming's lattice type is still unresolved (a Top
      // incoming with a known edge fact contributes Known(S) immediately)
      // and even when the incoming recovers to a wider declared type.
      //
      // Convergence note: as in transferTypedLoad, the per-incoming intersect
      // is not strictly monotone in the lattice state (a rescue can ascend
      // once from Top or Bottom to Known(S)); each value's trajectory is a
      // klass-chain-bounded sequence of descents plus such one-shot rescues,
      // sweeps run in deterministic program order, and the round cap is the
      // definitive backstop. Soundness is unaffected: every contribution is
      // the intersect of two independently sound facts, and metadata is only
      // attached after the fixpoint.
      Lattice R = Lattice::top();
      for (unsigned Idx = 0, E = PN->getNumIncomingValues(); Idx != E; ++Idx) {
        Lattice L = getLattice(PN->getIncomingValue(Idx));
        const jeandle::JavaType S = getEdgeSharpening(PN, Idx);
        if (L.isTop() && S.isUnknown())
          continue; // Top is the meet identity.
        jeandle::JavaType Combined = jeandle::typeIntersect(
            L.isKnown() ? jeandle::JavaType{L.Klass, L.Exact}
                        : jeandle::JavaType{},
            S);
        if (Combined.isKnown())
          R = meet(R, Lattice::known(Combined.Klass, Combined.Exact));
        else if (!L.isTop())
          R = meet(R, Lattice::bottom()); // contradiction (dead edge), or
                                          // provably unknowable
      }
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

  auto transferTypedLoad = [&](LoadInst *LI) -> Lattice {
    const LoadInfo &Info = LoadInfos[LI];
    Lattice BL = getLattice(Info.QueryBase);
    const jeandle::JavaType CtxType = getCtxType(LI);
    if (BL.isTop() && CtxType.isUnknown())
      return Lattice::top(); // base not resolved yet
    // Intersect the two views of the base's type: the lattice (declared or
    // recovered, including chains and loop-carried PHIs, which the query
    // cannot see because recovered metadata does not exist yet) and the cached
    // context-sensitive query (which additionally exploits instanceof
    // sharpening). Intersection takes the narrower of the two; each is
    // independently sound at the load. As the lattice descends the
    // intersection only descends (narrower, or Bottom when the two sources
    // contradict on a dead path), so the fixpoint still converges.
    jeandle::JavaType Combined = jeandle::typeIntersect(
        BL.isKnown() ? jeandle::JavaType{BL.Klass, BL.Exact}
                     : jeandle::JavaType{},
        CtxType);
    if (!Combined.isKnown())
      return BL.isTop() ? Lattice::top() : Lattice::bottom();
    // Array-ness first: ArrayElementKlass is non-zero exactly for object-array
    // klasses, while GetFieldType returns 0 for array klasses, so this
    // dispatch is unambiguous for both address shapes — including
    // constant-index aaloads, which are structurally identical to field
    // loads.
    if (uintptr_t EK = arrayElemKlass(Combined.Klass); EK != 0) {
      if (isUnvIface(EK))
        return Lattice::bottom(); // unverified interface element
      return Lattice::known(EK, isEffFinal(EK));
    }
    if (!Info.Offset)
      return Lattice::bottom(); // variable-index address on a non-array base:
                                // no element klass and no constant field
                                // offset to consult
    uintptr_t FK = getField(Combined.Klass, *Info.Offset);
    if (FK == 0 || isUnvIface(FK))
      return Lattice::bottom(); // no such field, or interface-typed
                                // (unverifiable)
    return Lattice::known(FK, isEffFinal(FK));
  };

  // ---------------------------------------------------------------------------
  // Fixpoint over the dynamic values (forwarders and tracked typed loads),
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
  // recomputed. Trajectories are descent-bounded (see the lattice comment
  // above); the cap is a defensive backstop.
  // ---------------------------------------------------------------------------
  SmallVector<Instruction *, 64> Dynamic;
  // Dynamic values are exactly those seeded Top (forwarders and tracked typed
  // loads). Collect them in program order — NOT over the pointer-keyed
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
      Lattice New;
      if (auto *LI = dyn_cast<LoadInst>(I); LI && LoadInfos.count(LI)) {
        // A tracked typed load.
        New = transferTypedLoad(LI);
      } else if (isForwarder(*I)) {
        // A forwarder (PHI / select / cast / freeze / zero-index GEP).
        New = transferForwarder(*I);
      } else {
        // Dynamic contains exactly the Top-seeded values, which are seeded
        // only as tracked typed loads or forwarders.
        llvm_unreachable(
            "dynamic value is neither a tracked load nor a forwarder");
      }
      Lattice &Old = States[I];
      if (Old != New) {
        Old = New;
        SweepChanged = true;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Emit: attach metadata to resolved typed loads that do not already have it.
  // ---------------------------------------------------------------------------
  bool Changed = false;
  for (BasicBlock &BB : F) {
    for (Instruction &I : BB) {
      auto *LI = dyn_cast<LoadInst>(&I);
      if (!LI || !isJavaOopType(LI->getType()))
        continue;
      if (LI->getMetadata(jeandle::Metadata::JavaKlass))
        continue; // already typed (frontend or a prior run) — leave untouched
      if (!LoadInfos.count(LI))
        continue; // not a tracked typed load (seed / opaque / non-oop base)
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
