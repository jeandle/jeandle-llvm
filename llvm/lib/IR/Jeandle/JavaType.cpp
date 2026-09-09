//===- JavaType.cpp - Java Type Query Implementation ----------------------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/IR/Jeandle/JavaType.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/ScopeExit.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/Statistic.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Jeandle/JeandleUtils.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Debug.h"
#include <cstdint>

#define DEBUG_TYPE "java-type"

using namespace llvm;
using namespace llvm::jeandle;

STATISTIC(NumJavaTypeBudgetExhausted,
          "Number of edge-facts queries that hit the per-query join budget");

// =============================================================================
// Helpers
// =============================================================================

/// Maximum recursion depth for extractKlassConstantImpl.
/// Prevents infinite recursion on deeply nested or cyclic IR patterns.
static constexpr unsigned MaxExtractKlassDepth = 16;

static uintptr_t extractKlassConstantImpl(Value *V, unsigned Depth) {
  if (Depth > MaxExtractKlassDepth)
    return 0;

  // Pattern A: freeze — LLVM may insert freeze for poison safety.
  // freeze ptr %klass has the same klass constant as %klass.
  // stripPointerCastsAndAliases does not look through FreezeInst.
  if (auto *FI = dyn_cast<FreezeInst>(V))
    return extractKlassConstantImpl(FI->getOperand(0), Depth + 1);

  // Strip pointer casts (bitcast, addrspacecast, zero-index GEP) and
  // aliases to see through wrappers that optimization passes may introduce.
  V = V->stripPointerCastsAndAliases();

  // Pattern 1: inttoptr instruction.
  if (auto *I2P = dyn_cast<IntToPtrInst>(V)) {
    Value *Src = I2P->getOperand(0);

    // Pattern B: look through zext/sext on the inttoptr operand.
    // Klass pointers are always positive (high bit zero), so zext/sext
    // from a narrower type preserves the value. TruncInst is NOT safe
    // because truncation can change the klass value.
    if (auto *Cast = dyn_cast<CastInst>(Src)) {
      if (isa<ZExtInst>(Cast) || isa<SExtInst>(Cast))
        Src = Cast->getOperand(0);
    }

    if (auto *CI = dyn_cast<ConstantInt>(Src))
      return CI->getZExtValue();
    // Handle inttoptr(ptrtoint(V)) chains — strip the round-trip and recurse.
    if (auto *P2I = dyn_cast<PtrToIntInst>(Src))
      return extractKlassConstantImpl(P2I->getPointerOperand(), Depth + 1);
    if (auto *CE = dyn_cast<ConstantExpr>(Src)) {
      if (CE->getOpcode() == Instruction::PtrToInt)
        return extractKlassConstantImpl(CE->getOperand(0), Depth + 1);
      // Handle zext/sext ConstantExpr wrapping a PtrToInt.
      if ((CE->getOpcode() == Instruction::ZExt ||
           CE->getOpcode() == Instruction::SExt) &&
          CE->getNumOperands() > 0) {
        auto *Inner = dyn_cast<ConstantExpr>(CE->getOperand(0));
        if (Inner && Inner->getOpcode() == Instruction::PtrToInt)
          return extractKlassConstantImpl(Inner->getOperand(0), Depth + 1);
      }
    }
  }
  // Pattern 2: inttoptr constant expression.
  if (auto *CE = dyn_cast<ConstantExpr>(V)) {
    if (CE->getOpcode() == Instruction::IntToPtr) {
      Value *Src = CE->getOperand(0);

      // Pattern B: look through zext/sext ConstantExpr.
      if (auto *InnerCE = dyn_cast<ConstantExpr>(Src)) {
        if (InnerCE->getOpcode() == Instruction::ZExt ||
            InnerCE->getOpcode() == Instruction::SExt)
          Src = InnerCE->getOperand(0);
      }

      if (auto *CI = dyn_cast<ConstantInt>(Src))
        return CI->getZExtValue();
      // Handle inttoptr(ptrtoint(V)) constant expression chain.
      if (auto *InnerCE = dyn_cast<ConstantExpr>(Src)) {
        if (InnerCE->getOpcode() == Instruction::PtrToInt)
          return extractKlassConstantImpl(InnerCE->getOperand(0), Depth + 1);
      }
    }
  }
  // Pattern 3: load from a constant global variable (recurse into initializer).
  if (auto *LI = dyn_cast<LoadInst>(V)) {
    if (auto *GV = dyn_cast<GlobalVariable>(
            LI->getPointerOperand()->stripPointerCastsAndAliases())) {
      if (GV->isConstant() && GV->hasInitializer())
        return extractKlassConstantImpl(GV->getInitializer(), Depth + 1);
    }
  }
  // Pattern 4: bare ConstantInt — only reachable via recursion from pattern 3
  // (e.g., @klass = constant i64 12345). Cannot appear as a direct ptr argument
  // to check_instanceof because LLVM enforces type safety.
  if (auto *CI = dyn_cast<ConstantInt>(V))
    return CI->getZExtValue();

  return 0;
}

uintptr_t jeandle::extractKlassConstant(Value *V) {
  return extractKlassConstantImpl(V, 0);
}

bool jeandle::areKlassesIncompatible(uintptr_t Klass, bool KlassExact,
                                     uintptr_t OtherKlass) {
  const VMCallbacks *CB = getVMCallbacks();
  assert(CB && CB->IsSubtype && CB->IsInterface && "VMCallbacks must be set");
  if (CB->IsSubtype(Klass, OtherKlass) || CB->IsInterface(Klass))
    return false;
  return KlassExact ||
         (!CB->IsSubtype(OtherKlass, Klass) && !CB->IsInterface(OtherKlass));
}

/// Return true if F is jeandle.check_instanceof.
static bool isCheckInstanceofFn(const Function *F) {
  return F && F->getName() == "jeandle.check_instanceof";
}

/// If CB is a call/invoke to jeandle.check_instanceof, return the super klass
/// and obj.
static bool isCheckInstanceofCall(const CallBase *CB, uintptr_t &Klass,
                                  Value *&Obj) {
  if (!isCheckInstanceofFn(CB->getCalledFunction()))
    return false;
  Klass = extractKlassConstant(CB->getArgOperand(0));
  Obj = CB->getArgOperand(1);
  return Klass != 0;
}

/// Check if klass K is excluded by set S, meaning there exists Y in S such
/// that IsSubtype(K, Y). Excluding Y implies excluding all subtypes of Y.
static bool isExcludedBy(uintptr_t K, const SmallDenseSet<uintptr_t, 2> &S) {
  const VMCallbacks *CB = getVMCallbacks();
  assert(CB && CB->IsSubtype && "VMCallbacks must be set");
  for (uintptr_t Y : S) {
    if (CB->IsSubtype(K, Y))
      return true;
  }
  return false;
}

/// Add an excluded klass to the set, maintaining the invariant that only the
/// most general (uppermost) excluded classes are stored.
static void addExcludedKlass(SmallDenseSet<uintptr_t, 2> &Set, uintptr_t K) {
  const VMCallbacks *CB = getVMCallbacks();
  assert(CB && CB->IsSubtype && "VMCallbacks must be set");

  // If K is already covered by a more general exclusion, skip.
  if (isExcludedBy(K, Set))
    return;

  // Remove any existing entries that are more specific than K.
  SmallVector<uintptr_t, 2> ToRemove;
  for (uintptr_t Y : Set) {
    if (CB->IsSubtype(Y, K))
      ToRemove.push_back(Y);
  }
  for (uintptr_t Y : ToRemove)
    Set.erase(Y);

  Set.insert(K);
}

/// Compute the subtype-aware intersection of two ExcludedKlasses sets.
/// A klass survives if it is excluded by BOTH sets.
static SmallDenseSet<uintptr_t, 2>
intersectExcludedKlasses(const SmallDenseSet<uintptr_t, 2> &A,
                         const SmallDenseSet<uintptr_t, 2> &B) {
  SmallDenseSet<uintptr_t, 2> Result;
  for (uintptr_t X : A) {
    if (isExcludedBy(X, B))
      addExcludedKlass(Result, X);
  }
  for (uintptr_t Y : B) {
    if (isExcludedBy(Y, A))
      addExcludedKlass(Result, Y);
  }
  return Result;
}

/// Merge ExcludedKlasses from Src into Dst (union). Both sets of negative
/// constraints apply to the same value at the same point.
static void unionExcludedKlasses(SmallDenseSet<uintptr_t, 2> &Dst,
                                 const SmallDenseSet<uintptr_t, 2> &Src) {
  for (uintptr_t K : Src)
    addExcludedKlass(Dst, K);
}

/// Enforce ExcludedKlasses invariants:
/// 1. If Exact, clear ExcludedKlasses (type is fully determined).
/// 2. If Klass is known, remove excluded klasses that are not subtypes of
///    Klass (they are already impossible).
static void normalizeExcludedKlasses(JavaType &T) {
  if (T.ExcludedKlasses.empty())
    return;
  if (T.Exact) {
    T.ExcludedKlasses.clear();
    return;
  }
  if (T.Klass != 0) {
    const VMCallbacks *CB = getVMCallbacks();
    assert(CB && CB->IsSubtype && "VMCallbacks must be set");
    SmallVector<uintptr_t, 2> ToRemove;
    for (uintptr_t K : T.ExcludedKlasses) {
      if (!CB->IsSubtype(K, T.Klass))
        ToRemove.push_back(K);
    }
    for (uintptr_t K : ToRemove)
      T.ExcludedKlasses.erase(K);
  }
}

static SmallDenseSet<uintptr_t, 2>
getFullInterfaces(uintptr_t Klass,
                  const SmallDenseSet<uintptr_t, 2> &PartialInterfaces) {
  const VMCallbacks *CB = getVMCallbacks();
  assert(CB && CB->GetSecondarySupers && CB->IsInterface &&
         "VMCallbacks must be set");
  SmallDenseSet<uintptr_t, 2> Result;
  if (Klass != 0) {
    if (CB->IsInterface(Klass)) {
      Result.insert(Klass);
    }
    std::vector<uintptr_t> KlassInterfaces = CB->GetSecondarySupers(Klass);
    for (uintptr_t I : KlassInterfaces) {
      Result.insert(I);
    }
  }
  SmallDenseSet<uintptr_t, 2> IncInterfaces = Result;
  while (!IncInterfaces.empty()) {
    SmallDenseSet<uintptr_t, 2> NewIncInterfaces;
    for (uintptr_t I : IncInterfaces) {
      std::vector<uintptr_t> SuperInterfaces = CB->GetSecondarySupers(I);
      for (uintptr_t SI : SuperInterfaces) {
        if (!Result.contains(SI)) {
          NewIncInterfaces.insert(SI);
          Result.insert(SI);
        }
      }
    }
    IncInterfaces = NewIncInterfaces;
  }
  return Result;
}

jeandle::JavaType::JavaType(uintptr_t Klass, bool Exact)
    : Klass(Klass), Exact(Exact) {
  this->Interfaces = getFullInterfaces(Klass, {});
}

JavaType jeandle::typeUnion(JavaType A, JavaType B) {
  JavaType Result;
  for (uintptr_t I : A.Interfaces) {
    if (B.Interfaces.contains(I)) {
      Result.Interfaces.insert(I);
    }
  }
  if (A.Klass == 0 && B.Klass == 0) {
    // Both have unknown positive type. Intersect exclusions.
    if (!A.ExcludedKlasses.empty() && !B.ExcludedKlasses.empty())
      Result.ExcludedKlasses =
          intersectExcludedKlasses(A.ExcludedKlasses, B.ExcludedKlasses);
    return Result;
  }
  if (A.Klass == 0 || B.Klass == 0) {
    // One known Klass, one unknown. Ensure A has the known Klass.
    if (A.Klass == 0)
      std::swap(A, B);
    // Drop positive type (value could come from the unknown side).
    // Preserve exclusions from B that are also excluded by A's knowledge.
    if (!B.ExcludedKlasses.empty()) {
      for (uintptr_t E : B.ExcludedKlasses) {
        // E is excluded on B's path (explicit). Check A's path:
        // either A explicitly excludes E, or A's class type makes E impossible.
        if (isExcludedBy(E, A.ExcludedKlasses) ||
            areKlassesIncompatible(A.Klass, A.Exact, E)) {
          addExcludedKlass(Result.ExcludedKlasses, E);
        }
      }
    }
    return Result;
  }
  if (A.Klass == B.Klass) {
    Result.Klass = A.Klass;
    Result.Exact = A.Exact && B.Exact;
  } else {
    const VMCallbacks *CB = getVMCallbacks();
    assert(CB && CB->GetCommonSuperKlass && "VMCallbacks must be set");
    uintptr_t LCA = CB->GetCommonSuperKlass(A.Klass, B.Klass);
    if (LCA == 0)
      return {};
    Result.Klass = LCA;
    Result.Exact = false;
  }
  // Intersect exclusions (value could be either A or B).
  if (!A.ExcludedKlasses.empty() && !B.ExcludedKlasses.empty())
    Result.ExcludedKlasses =
        intersectExcludedKlasses(A.ExcludedKlasses, B.ExcludedKlasses);
  normalizeExcludedKlasses(Result);
  return Result;
}

JavaType jeandle::typeIntersect(JavaType A, JavaType B) {
  JavaType Result;
  for (uintptr_t I : A.Interfaces) {
    Result.Interfaces.insert(I);
  }
  for (uintptr_t I : B.Interfaces) {
    Result.Interfaces.insert(I);
  }
  // Positive type: pick the more specific one.
  if (A.isKnown() && B.isKnown()) {
    const VMCallbacks *CB = getVMCallbacks();
    assert(CB && CB->IsSubtype && "VMCallbacks must be set");
    if (A.Klass == B.Klass) {
      // Equal klass: Exact is conjunctive. Exact=true is the stricter claim
      // ("value is exactly this class"), so if either operand is exact the
      // intersection is exact. IsSubtype is reflexive, so without this case
      // the first branch below would win and silently drop the other side's
      // Exact. (Dual of typeUnion's A.Exact && B.Exact for the equal case.)
      Result.Klass = A.Klass;
      Result.Exact = A.Exact || B.Exact;
    } else if (A.Exact != B.Exact) {
      // Exactly one side is Exact: an exact claim is a complete dynamic-type
      // claim (allocation type, constant oop's runtime klass, or a final
      // klass proven by a passing check), so the exact side is always at
      // least as strong as anything the other side could contribute. When the
      // two sides are also inconsistent (no common subtype — only reachable
      // with different klasses here), no live value satisfies both claims and
      // the program point is dead, so keeping the exact side is vacuously
      // sound there and avoids needlessly degrading to unknown.
      Result.Klass = A.Exact ? A.Klass : B.Klass;
      Result.Exact = true;
    } else if (CB->IsSubtype(A.Klass, B.Klass)) {
      Result.Klass = A.Klass;
      Result.Exact = A.Exact;
    } else if (CB->IsSubtype(B.Klass, A.Klass)) {
      Result.Klass = B.Klass;
      Result.Exact = B.Exact;
    }
    // else: neither is a subtype of the other — contradictory constraints
    // (dead code). Leave Result.Klass = 0 (unknown).
  } else if (A.isKnown()) {
    Result.Klass = A.Klass;
    Result.Exact = A.Exact;
  } else if (B.isKnown()) {
    Result.Klass = B.Klass;
    Result.Exact = B.Exact;
  }

  // Negative constraints: union (both exclusions apply at the same point).
  Result.ExcludedKlasses = A.ExcludedKlasses;
  unionExcludedKlasses(Result.ExcludedKlasses, B.ExcludedKlasses);
  normalizeExcludedKlasses(Result);

  return Result;
}

// =============================================================================
// Context-insensitive type query
// =============================================================================

/// Memo of complete base-type computations, keyed by value alone: a base
/// type is a pure function of the value (attributes, metadata, constant oop
/// identity, PHI/select structure), never of the query point. Entries are
/// written only for computations that never hit a PHI cycle — a cycle-hit
/// result depends on where the recursion was cut and must not be reused.
/// Cycle-aware memoization keeps shared PHI sub-DAGs linear: without it, a
/// chain of PHIs whose arms share children costs 2^depth.
using BaseMemo = DenseMap<Value *, JavaType>;

/// Join one more arm into an accumulator where the first arm seeds it:
/// typeUnion treats unknown as absorbing (typeUnion({}, X) == {}), so the
/// first arm must seed the accumulator rather than union into an empty one.
static void joinArm(JavaType &Acc, bool &First, JavaType Arm) {
  if (First) {
    Acc = std::move(Arm);
    First = false;
  } else {
    Acc = typeUnion(Acc, Arm);
  }
}

// No exclusions during context-insensitive type query.
static JavaType getBaseJavaTypeRaw(Value *V,
                                   SmallPtrSetImpl<const PHINode *> &Visited,
                                   BaseMemo &Memo, bool &CycleHit, bool IsRoot);

static JavaType getBaseJavaTypeCase(Value *V,
                                    SmallPtrSetImpl<const PHINode *> &Visited,
                                    BaseMemo &Memo, bool &CycleHit) {
  // Argument: check param attributes.
  if (auto *Arg = dyn_cast<Argument>(V)) {
    const Function *F = Arg->getParent();
    unsigned Idx = Arg->getArgNo();
    const AttributeList &AL = F->getAttributes();
    if (AL.hasParamAttr(Idx, jeandle::Attribute::JavaKlass)) {
      StringRef KlassStr = AL.getParamAttr(Idx, jeandle::Attribute::JavaKlass)
                               .getValueAsString();
      uintptr_t Klass = 0;
      if (!KlassStr.getAsInteger(10, Klass) && Klass != 0) {
        bool Exact = AL.hasParamAttr(Idx, jeandle::Attribute::JavaKlassExact);
        return {Klass, Exact};
      }
    }
    return {};
  }

  // Call / Invoke: check return attributes.
  if (auto *CB = dyn_cast<CallBase>(V)) {
    const AttributeList &AL = CB->getAttributes();
    if (AL.hasRetAttr(jeandle::Attribute::JavaKlass)) {
      StringRef KlassStr = AL.getAttributeAtIndex(AttributeList::ReturnIndex,
                                                  jeandle::Attribute::JavaKlass)
                               .getValueAsString();
      uintptr_t Klass = 0;
      if (!KlassStr.getAsInteger(10, Klass) && Klass != 0) {
        bool Exact = AL.hasRetAttr(jeandle::Attribute::JavaKlassExact);
        return {Klass, Exact};
      }
    }
    return {};
  }

  // Load: check !java-klass metadata.
  if (auto *LI = dyn_cast<LoadInst>(V)) {
    if (MDNode *MD = LI->getMetadata(jeandle::Metadata::JavaKlass)) {
      if (MD->getNumOperands() >= 1) {
        if (auto *CMD = dyn_cast<ConstantAsMetadata>(MD->getOperand(0))) {
          if (auto *CI = dyn_cast<ConstantInt>(CMD->getValue())) {
            uintptr_t Klass = CI->getZExtValue();
            if (Klass != 0) {
              bool Exact =
                  LI->getMetadata(jeandle::Metadata::JavaKlassExact) != nullptr;
              return {Klass, Exact};
            }
          }
        }
      }
    }

    // Constant oop: the frontend emits a compile-time-known object reference
    // as an oop_handle_* global load WITHOUT !java-klass metadata. Recognize
    // the handle by name and query the oop's exact runtime klass via the VM.
    // Exact is sound because a constant oop is a single, fixed instance, so the
    // returned klass is the value's exact dynamic type (the actual subclass is
    // attributed directly, not a declared supertype).
    if (std::optional<int> Id = getOopHandleId(LI->getPointerOperand())) {
      const VMCallbacks *CB = getVMCallbacks();
      if (CB && CB->GetOopKlass) {
        if (uintptr_t Klass = CB->GetOopKlass(*Id); Klass != 0) {
          return {Klass, /*Exact=*/true};
        }
      }
    }
    return {};
  }

  // PHI: compute LCA of all incoming values. The visited set is a recursion
  // stack, not a whole-query cache: an incoming PHI is skipped only while it
  // is on the stack (a true cycle — the type is then determined by the values
  // entering the cycle, which are exactly the non-cyclic incomings). Skipping
  // a merely-visited PHI would silently drop it from the LCA and produce a
  // too-narrow type when the same PHI feeds two different arms.
  if (auto *PN = dyn_cast<PHINode>(V)) {
    if (!Visited.insert(PN).second) {
      CycleHit = true;
      return {}; // Cycle detected — caller will skip this incoming.
    }
    auto StackGuard = make_scope_exit([&]() { Visited.erase(PN); });
    JavaType Result;
    bool First = true;
    for (unsigned I = 0, E = PN->getNumIncomingValues(); I != E; ++I) {
      Value *Inc = PN->getIncomingValue(I);
      if (auto *IncPN = dyn_cast<PHINode>(Inc)) {
        if (Visited.count(IncPN)) {
          CycleHit = true;
          continue; // Skip cyclic incoming.
        }
      }
      // JavaType does not model nullability. Any positive facts derived from
      // jeandle.check_instanceof remain sound here only because current
      // consumers query it under check_instanceof's non-null oop contract.
      // CycleHit is frame-local: a sibling's earlier cycle must not disable
      // this frame's memoization, so each child gets its own flag and only
      // the disjunction propagates upward.
      bool ChildHit = false;
      JavaType IncType =
          getBaseJavaTypeRaw(Inc, Visited, Memo, ChildHit, /*IsRoot=*/false);
      CycleHit |= ChildHit;
      if (IncType.isUnknown())
        return {};
      joinArm(Result, First, IncType);
      if (Result.isUnknown())
        return {};
    }
    return Result;
  }

  // Select: LCA of both operands.
  if (auto *SI = dyn_cast<SelectInst>(V)) {
    bool TrueHit = false;
    JavaType TrueType = getBaseJavaTypeRaw(SI->getTrueValue(), Visited, Memo,
                                           TrueHit, /*IsRoot=*/false);
    if (TrueType.isUnknown()) {
      CycleHit |= TrueHit;
      return {};
    }
    bool FalseHit = false;
    JavaType FalseType = getBaseJavaTypeRaw(SI->getFalseValue(), Visited, Memo,
                                            FalseHit, /*IsRoot=*/false);
    CycleHit |= TrueHit || FalseHit;
    return typeUnion(TrueType, FalseType);
  }

  // BitCast / AddrSpaceCast / Freeze: pass through.
  if (auto *BC = dyn_cast<BitCastInst>(V)) {
    bool ChildHit = false;
    JavaType R = getBaseJavaTypeRaw(BC->getOperand(0), Visited, Memo, ChildHit,
                                    /*IsRoot=*/false);
    CycleHit |= ChildHit;
    return R;
  }
  if (auto *ASC = dyn_cast<AddrSpaceCastInst>(V)) {
    bool ChildHit = false;
    JavaType R = getBaseJavaTypeRaw(ASC->getOperand(0), Visited, Memo, ChildHit,
                                    /*IsRoot=*/false);
    CycleHit |= ChildHit;
    return R;
  }
  if (auto *FI = dyn_cast<FreezeInst>(V)) {
    bool ChildHit = false;
    JavaType R = getBaseJavaTypeRaw(FI->getOperand(0), Visited, Memo, ChildHit,
                                    /*IsRoot=*/false);
    CycleHit |= ChildHit;
    return R;
  }

  return {};
}

// =============================================================================
/// Frame-level memoizing driver around getBaseJavaTypeCase: one frame per
/// value; cache on completion when the frame's own sub-computation never hit
/// a PHI cycle, or unconditionally for the query's root (see BaseMemo).
static JavaType getBaseJavaTypeRaw(Value *V,
                                   SmallPtrSetImpl<const PHINode *> &Visited,
                                   BaseMemo &Memo, bool &CycleHit,
                                   bool IsRoot) {
  if (auto It = Memo.find(V); It != Memo.end())
    return It->second;
  JavaType R = getBaseJavaTypeCase(V, Visited, Memo, CycleHit);
  if (IsRoot || !CycleHit)
    Memo[V] = R;
  return R;
}

/// Base-type query root. Pass a Memo to share the completion cache across a
/// whole query (the engine's value dimension does); without one, a fresh
/// per-call cache is used (the base-only query path).
static JavaType getBaseJavaType(Value *V,
                                SmallPtrSetImpl<const PHINode *> &Visited,
                                BaseMemo *Memo = nullptr) {
  BaseMemo LocalMemo;
  BaseMemo &Cache = Memo ? *Memo : LocalMemo;
  bool CycleHit = false;
  return getBaseJavaTypeRaw(V, Visited, Cache, CycleHit, /*IsRoot=*/true);
}

// Condition tracing: trace from a branch condition to a check_instanceof call
// =============================================================================

namespace {

/// Result of tracing a branch condition back to jeandle.check_instanceof calls.
///
/// Given a conditional branch `br i1 %cond, label %true_bb, label %false_bb`,
/// traceToCheckInstanceof determines type constraints for each branch:
///
///   True-branch constraints (condition is true):
///   - TrueKlass: positive constraint — obj IS this type (0 if unknown).
///   - TrueExclusions: negative constraints — obj IS NOT these types.
///
///   False-branch constraints (condition is false):
///   - FalseKlass: positive constraint — obj IS this type (0 if unknown).
///   - FalseExclusions: negative constraints — obj IS NOT these types.
///
/// Merge semantics are handled by each handler:
///   - And true-branch: AllOf (both operands true) — pickMostSpecific + union.
///   - And false-branch: OneOf (at least one false) — computeLCA + intersect.
///   - Or true-branch: OneOf (at least one true) — computeLCA + intersect.
///   - Or false-branch: AllOf (both operands false) — pickMostSpecific + union.
///   - Xor i1 %a, true: logical NOT
///   - PHI/Select: OneOf (one arm selected) — computeLCA + intersect.
///   - ICmp inversion: swap True ↔ False fields.
///
/// De Morgan duality (And of negated checks) is handled automatically:
/// ICmp swaps True/False before And merges, so And(NOT A, NOT B) correctly
/// produces TrueExclusions = {A, B} (both checks failed on true-branch).
struct TraceResult {
  uintptr_t TrueKlass = 0;
  SmallDenseSet<uintptr_t, 2> TrueInterfaces;
  SmallDenseSet<uintptr_t, 2> TrueExclusions;
  uintptr_t FalseKlass = 0;
  SmallDenseSet<uintptr_t, 2> FalseInterfaces;
  SmallDenseSet<uintptr_t, 2> FalseExclusions;

  bool matched() const {
    return TrueKlass != 0 || !TrueInterfaces.empty() ||
           !TrueExclusions.empty() || FalseKlass != 0 ||
           !FalseInterfaces.empty() || !FalseExclusions.empty();
  }
};

} // anonymous namespace

/// Match `jeandle.check_exact_klass(ExpectedKlass, ActualKlass)`, where
/// one argument is loaded directly from `QueryObj` by `jeandle.load_klass`.
/// The intrinsic arguments are treated symmetrically because IR rewrites may
/// place the loaded Klass in either position.
static bool isLoadKlassOf(Value *ValueToCheck, Value *QueryObj) {
  auto *Load = dyn_cast<CallBase>(ValueToCheck->stripPointerCastsAndAliases());
  return Load && Load->getCalledFunction() &&
         Load->getCalledFunction()->getName() == "jeandle.load_klass" &&
         Load->arg_size() == 1 &&
         Load->getArgOperand(0)->stripPointerCastsAndAliases() ==
             QueryObj->stripPointerCastsAndAliases();
}

static uintptr_t traceExactKlassGuard(Value *Cond, Value *QueryObj) {
  auto *CB = dyn_cast<CallBase>(Cond);
  Function *Callee = CB ? CB->getCalledFunction() : nullptr;
  if (!Callee || Callee->getName() != "jeandle.check_exact_klass" ||
      CB->arg_size() != 2)
    return 0;

  bool FirstIsActual = isLoadKlassOf(CB->getArgOperand(0), QueryObj);
  bool SecondIsActual = isLoadKlassOf(CB->getArgOperand(1), QueryObj);
  if (FirstIsActual == SecondIsActual)
    return 0;

  Value *ExpectedKlass =
      FirstIsActual ? CB->getArgOperand(1) : CB->getArgOperand(0);
  return extractKlassConstant(ExpectedKlass);
}

/// AllOf: pick the more specific klass (both confirmed — tighter bound).
/// Returns 0 if unrelated (e.g., two interfaces an object can implement).
static uintptr_t pickMostSpecific(uintptr_t A, uintptr_t B) {
  if (A == 0)
    return B;
  if (B == 0)
    return A;
  const VMCallbacks *CB = getVMCallbacks();
  assert(CB && CB->IsSubtype && "VMCallbacks must be set");
  if (CB->IsSubtype(A, B))
    return A;
  if (CB->IsSubtype(B, A))
    return B;
  return 0; // Unrelated — no useful positive constraint.
}

/// OneOf: compute LCA (don't know which — weakest common bound).
static uintptr_t computeLCA(uintptr_t A, uintptr_t B) {
  if (A == 0 || B == 0)
    return 0;
  if (A == B)
    return A;
  const VMCallbacks *CB = getVMCallbacks();
  assert(CB && CB->GetCommonSuperKlass && "VMCallbacks must be set");
  return CB->GetCommonSuperKlass(A, B);
}

/// Interfaces provable under a OneOf merge (at least one of the merged
/// outcomes held): only interfaces carried by every outcome survive. This is
/// a set INTERSECTION.
static SmallDenseSet<uintptr_t, 2>
commonInterfaces(const SmallDenseSet<uintptr_t, 2> &InterfacesA,
                 const SmallDenseSet<uintptr_t, 2> &InterfacesB) {
  SmallDenseSet<uintptr_t, 2> R;
  for (uintptr_t I : InterfacesA) {
    if (InterfacesB.contains(I)) {
      R.insert(I);
    }
  }
  return R;
}

/// Interfaces provable under an AllOf merge (every merged outcome held): the
/// union of all carried interfaces. This is a set UNION.
static SmallDenseSet<uintptr_t, 2>
combinedInterfaces(const SmallDenseSet<uintptr_t, 2> &A,
                   const SmallDenseSet<uintptr_t, 2> &B) {
  SmallDenseSet<uintptr_t, 2> Result = A;
  for (uintptr_t I : B) {
    Result.insert(I);
  }
  return Result;
}

/// Strip pointer casts, aliases and freeze wrappers down to the canonical
/// underlying value. freeze is transparent for value identity: freeze(x)
/// equals x unless x is poison, and a branch on poison has undefined
/// behavior, so facts proved about x transfer to freeze(x) and vice versa.
static Value *stripCastsAndFreeze(Value *V) {
  while (true) {
    V = V->stripPointerCastsAndAliases();
    if (auto *FI = dyn_cast<FreezeInst>(V)) {
      V = FI->getOperand(0);
      continue;
    }
    return V;
  }
}

/// Check if IncomingBB is reached only when Obj is null.
/// Walks up the dominator tree from IncomingBB looking for a conditional branch
/// on `icmp eq/ne Obj, null` where IncomingBB is dominated by the "Obj is null"
/// successor. Using the dominator tree handles all CFG shapes (diamonds, etc.),
/// not just single-predecessor chains. Only branches are recognized: switch
/// case values must be constant integers, so a switch can never test a
/// pointer against null.
static bool isNullCheckPath(BasicBlock *IncomingBB, Value *Obj,
                            DominatorTree &DT) {
  Obj = Obj->stripPointerCastsAndAliases();
  for (auto *Node = DT.getNode(IncomingBB); Node; Node = Node->getIDom()) {
    BasicBlock *BB = Node->getBlock();

    if (auto *BI = dyn_cast<BranchInst>(BB->getTerminator())) {
      if (!BI->isConditional())
        continue;
      auto *Cmp = dyn_cast<ICmpInst>(BI->getCondition());
      if (!Cmp)
        continue;
      ICmpInst::Predicate Pred = Cmp->getPredicate();
      if (Pred != ICmpInst::ICMP_EQ && Pred != ICmpInst::ICMP_NE)
        continue;
      Value *Op0 = Cmp->getOperand(0);
      Value *Op1 = Cmp->getOperand(1);
      Value *Tested = isa<ConstantPointerNull>(Op0)   ? Op1
                      : isa<ConstantPointerNull>(Op1) ? Op0
                                                      : nullptr;
      if (!Tested || Tested->stripPointerCastsAndAliases() != Obj)
        continue;
      // icmp eq Obj, null -> true successor is the null path;
      // icmp ne Obj, null -> false successor is the null path.
      BasicBlock *NullBB =
          Pred == ICmpInst::ICMP_EQ ? BI->getSuccessor(0) : BI->getSuccessor(1);
      BasicBlock *OtherBB =
          Pred == ICmpInst::ICMP_EQ ? BI->getSuccessor(1) : BI->getSuccessor(0);
      if (NullBB == OtherBB)
        continue;
      // IncomingBB must be dominated by the null-path edge.
      if (DT.dominates(BasicBlockEdge(BB, NullBB), IncomingBB))
        return true;
    }
  }
  return false;
}

/// Recursively trace a branch condition back to a jeandle.check_instanceof
/// call on QueryObj. Returns a matched TraceResult if successful, or an
/// unmatched TraceResult ({Klass=0}) if the condition cannot be linked to a
/// check_instanceof on QueryObj.
static TraceResult traceToCheckInstanceof(Value *Cond, Value *QueryObj,
                                          SmallPtrSetImpl<Value *> &Visited,
                                          DominatorTree &DT) {
  QueryObj = QueryObj->stripPointerCastsAndAliases();
  // Avoid infinite recursion on cyclic value graphs.
  if (!Visited.insert(Cond).second)
    return {}; // Already visited — no match on this path.

  // --- Base case: direct call/invoke to jeandle.check_instanceof ---
  if (auto *CB = dyn_cast<CallBase>(Cond)) {
    uintptr_t Klass = 0;
    Value *Obj = nullptr;
    if (isCheckInstanceofCall(CB, Klass, Obj) &&
        Obj->stripPointerCastsAndAliases() == QueryObj) {
      TraceResult R;
      R.TrueKlass = Klass; // check passed → obj IS Klass
      R.TrueInterfaces = getFullInterfaces(Klass, {});
      R.FalseExclusions.insert(Klass); // check failed → obj IS NOT Klass
      return R;
    }
    return {}; // Not a check_instanceof on QueryObj.
  }

  // --- ICmp: comparisons that test the result of a type check ---
  //
  // The value being compared ultimately derives from a check_instanceof, which
  // returns i1 (0 or 1). It may have been widened (e.g., zext i1 to i32), but
  // the only meaningful values are 0 (check failed) and 1 (check passed).
  //
  // Rather than matching specific predicates (eq, ne) against specific
  // constants (0, 1), we use a general approach: evaluate what the comparison
  // returns for each possible input (0 and 1), then determine whether it
  // discriminates between "check passed" and "check failed".
  //
  // Examples of how this works:
  //
  //   `icmp ne i32 %val, 0`:
  //     val=0 → ne(0,0) → false    val=1 → ne(1,0) → true
  //     Discriminating: true when check passed → not negated.
  //
  //   `icmp eq i32 %val, 0`:
  //     val=0 → eq(0,0) → true     val=1 → eq(1,0) → false
  //     Discriminating: true when check failed → negated.
  //
  //   `icmp sgt i32 %val, 0`:
  //     val=0 → sgt(0,0) → false   val=1 → sgt(1,0) → true
  //     Discriminating: true when check passed → not negated.
  //
  //   `icmp uge i32 %val, 1`:
  //     val=0 → uge(0,1) → false   val=1 → uge(1,1) → true
  //     Discriminating: true when check passed → not negated.
  //
  //   `icmp sge i32 %val, 0`:
  //     val=0 → sge(0,0) → true    val=1 → sge(1,0) → true
  //     Both true → always true, not discriminating → no match.
  //
  if (auto *Cmp = dyn_cast<ICmpInst>(Cond)) {
    Value *LHS = Cmp->getOperand(0);
    Value *RHS = Cmp->getOperand(1);
    auto Pred = Cmp->getPredicate();

    // Normalize so the constant is always on the RHS, adjusting the predicate
    // accordingly. E.g., `icmp sgt 0, %val` becomes `icmp slt %val, 0`.
    Value *Val = LHS;
    ConstantInt *C = dyn_cast<ConstantInt>(RHS);
    if (!C) {
      C = dyn_cast<ConstantInt>(LHS);
      Val = RHS;
      Pred = ICmpInst::getSwappedPredicate(Pred);
    }
    if (C) {
      // Evaluate `icmp Pred %val, C` for the two possible boolean inputs.
      unsigned BitWidth = C->getType()->getIntegerBitWidth();
      APInt ZeroVal(BitWidth, 0);
      APInt OneVal(BitWidth, 1);
      bool ResultForZero = ICmpInst::compare(ZeroVal, C->getValue(), Pred);
      bool ResultForOne = ICmpInst::compare(OneVal, C->getValue(), Pred);

      if (ResultForZero != ResultForOne) {
        // The comparison discriminates between 0 and 1 — it tells us whether
        // the underlying check_instanceof passed or failed. Now trace the
        // non-constant operand to find that check_instanceof.
        TraceResult R = traceToCheckInstanceof(Val, QueryObj, Visited, DT);
        if (!R.matched())
          return {}; // Val doesn't trace to a check — no match.
        if (ResultForOne)
          // The comparison returns true when val=1 (check passed).
          // True/False constraints are unchanged.
          return R;
        else {
          // The comparison returns true when val=0 (check failed).
          // Swap True ↔ False constraints.
          std::swap(R.TrueKlass, R.FalseKlass);
          std::swap(R.TrueInterfaces, R.FalseInterfaces);
          std::swap(R.TrueExclusions, R.FalseExclusions);
          return R;
        }
      }
      // ResultForZero == ResultForOne: the comparison is always true or always
      // false regardless of the check result (e.g., `sge %val, 0` is always
      // true for {0,1}). It provides no type information.
    }
    return {}; // No constant operand, or not discriminating — no match.
  }

  // --- ZExt / SExt / Trunc: transparent casts, trace through to source ---
  // (e.g., `zext i1 %check_instanceof_result to i32`)
  if (auto *Cast = dyn_cast<CastInst>(Cond)) {
    if (isa<ZExtInst>(Cast) || isa<SExtInst>(Cast) || isa<TruncInst>(Cast))
      return traceToCheckInstanceof(Cast->getOperand(0), QueryObj, Visited, DT);
    return {}; // Other casts (bitcast, fpcast, ...) — not meaningful here.
  }

  // --- And i1 %a, %b ---
  // True-branch: both operands are true → AllOf (both constraints hold).
  // False-branch: at least one is false → OneOf (don't know which failed).
  if (auto *BO = dyn_cast<BinaryOperator>(Cond)) {
    if (BO->getOpcode() == Instruction::And) {
      TraceResult L =
          traceToCheckInstanceof(BO->getOperand(0), QueryObj, Visited, DT);
      TraceResult R =
          traceToCheckInstanceof(BO->getOperand(1), QueryObj, Visited, DT);
      if (L.matched() && R.matched()) {
        TraceResult M;
        // True-branch: both L and R are true → AllOf.
        M.TrueKlass = pickMostSpecific(L.TrueKlass, R.TrueKlass);
        M.TrueInterfaces =
            combinedInterfaces(L.TrueInterfaces, R.TrueInterfaces);
        M.TrueExclusions = L.TrueExclusions;
        unionExcludedKlasses(M.TrueExclusions, R.TrueExclusions);
        // False-branch: at least one of L, R is false → OneOf.
        M.FalseKlass = computeLCA(L.FalseKlass, R.FalseKlass);
        M.FalseInterfaces =
            commonInterfaces(L.FalseInterfaces, R.FalseInterfaces);
        M.FalseExclusions =
            intersectExcludedKlasses(L.FalseExclusions, R.FalseExclusions);
        return M;
      }
      // Only one side matched. True-branch is sound (both must be true for
      // And to be true, so the matched operand is guaranteed true).
      // False-branch is unsound: And being false could be due to the
      // unmatched operand, not the matched one.
      if (L.matched()) {
        TraceResult M;
        M.TrueKlass = L.TrueKlass;
        M.TrueInterfaces = L.TrueInterfaces;
        M.TrueExclusions = L.TrueExclusions;
        return M;
      }
      if (R.matched()) {
        TraceResult M;
        M.TrueKlass = R.TrueKlass;
        M.TrueInterfaces = R.TrueInterfaces;
        M.TrueExclusions = R.TrueExclusions;
        return M;
      }
      return {};
    }
    // --- Or i1 %a, %b --- (De Morgan dual of And)
    // True-branch: at least one operand is true → OneOf (don't know which).
    // False-branch: both operands are false → AllOf (both constraints hold).
    if (BO->getOpcode() == Instruction::Or) {
      TraceResult L =
          traceToCheckInstanceof(BO->getOperand(0), QueryObj, Visited, DT);
      TraceResult R =
          traceToCheckInstanceof(BO->getOperand(1), QueryObj, Visited, DT);
      if (L.matched() && R.matched()) {
        TraceResult M;
        // True-branch: at least one of L, R is true → OneOf.
        M.TrueKlass = computeLCA(L.TrueKlass, R.TrueKlass);
        M.TrueInterfaces = commonInterfaces(L.TrueInterfaces, R.TrueInterfaces);
        M.TrueExclusions =
            intersectExcludedKlasses(L.TrueExclusions, R.TrueExclusions);
        // False-branch: both L and R are false → AllOf.
        M.FalseKlass = pickMostSpecific(L.FalseKlass, R.FalseKlass);
        M.FalseInterfaces =
            combinedInterfaces(L.FalseInterfaces, R.FalseInterfaces);
        M.FalseExclusions = L.FalseExclusions;
        unionExcludedKlasses(M.FalseExclusions, R.FalseExclusions);
        return M;
      }
      // Only one side matched. False-branch is sound (both must be false for
      // Or to be false, so the matched operand is guaranteed false).
      // True-branch is unsound: Or being true could be due to the
      // unmatched operand, not the matched one.
      if (L.matched()) {
        TraceResult M;
        M.FalseKlass = L.FalseKlass;
        M.FalseInterfaces = L.FalseInterfaces;
        M.FalseExclusions = L.FalseExclusions;
        return M;
      }
      if (R.matched()) {
        TraceResult M;
        M.FalseKlass = R.FalseKlass;
        M.FalseInterfaces = R.FalseInterfaces;
        M.FalseExclusions = R.FalseExclusions;
        return M;
      }
      return {};
    }
    // --- Xor i1 %a, true: logical NOT ---
    // xor i1 %val, true is equivalent to !val. Trace the non-constant
    // operand and swap True/False constraints.
    // Note: xor i1 %val, false is simplified away by InstSimplify, so
    // only the true-constant case needs handling.
    if (BO->getOpcode() == Instruction::Xor) {
      Value *LHS = BO->getOperand(0);
      Value *RHS = BO->getOperand(1);
      auto *LHSC = dyn_cast<ConstantInt>(LHS);
      auto *RHSC = dyn_cast<ConstantInt>(RHS);

      // We need exactly one constant-true operand.
      Value *NonConstVal = nullptr;
      if (LHSC && LHSC->isOne() && !RHSC)
        NonConstVal = RHS;
      else if (RHSC && RHSC->isOne() && !LHSC)
        NonConstVal = LHS;

      if (NonConstVal) {
        TraceResult R =
            traceToCheckInstanceof(NonConstVal, QueryObj, Visited, DT);
        if (!R.matched())
          return {};
        // xor with true inverts the condition → swap True/False.
        std::swap(R.TrueKlass, R.FalseKlass);
        std::swap(R.TrueInterfaces, R.FalseInterfaces);
        std::swap(R.TrueExclusions, R.FalseExclusions);
        return R;
      }
      return {};
    }

    return {}; // Other binary ops — not handled.
  }

  // --- Select: the result is one of two values, we don't know which ---
  // Both branches use OneOf semantics: LCA for klass, intersect for exclusions.
  // Special case: if one arm is a constant, the other arm's constraints can
  // be used directly on the branch where the constant could not contribute.
  //   - Constant false arm: on true-branch, this arm can't be selected →
  //     other arm was selected and is true → use other arm's True constraints.
  //   - Constant true arm: on false-branch, this arm can't be selected →
  //     other arm was selected and is false → use other arm's False
  //     constraints.
  if (auto *SI = dyn_cast<SelectInst>(Cond)) {
    Value *TrueVal = SI->getTrueValue();
    Value *FalseVal = SI->getFalseValue();
    auto *TrueConst = dyn_cast<ConstantInt>(TrueVal);
    auto *FalseConst = dyn_cast<ConstantInt>(FalseVal);

    // Both constant → no check_instanceof involved.
    if (TrueConst && FalseConst)
      return {};

    // One arm is constant.
    if (TrueConst || FalseConst) {
      bool IsZero = TrueConst ? TrueConst->isZero() : FalseConst->isZero();
      Value *NonConstVal = TrueConst ? FalseVal : TrueVal;
      TraceResult R =
          traceToCheckInstanceof(NonConstVal, QueryObj, Visited, DT);
      if (!R.matched())
        return {};
      TraceResult M;
      if (IsZero) {
        // Constant false: on the select's true-branch, the constant arm can't
        // be selected → the non-constant arm was selected and is true.
        M.TrueKlass = R.TrueKlass;
        M.TrueInterfaces = R.TrueInterfaces;
        M.TrueExclusions = R.TrueExclusions;
        // False-branch: could be constant false or R false → no useful info.
      } else {
        // Constant true: on the select's false-branch, the constant arm can't
        // be selected → the non-constant arm was selected and is false.
        M.FalseKlass = R.FalseKlass;
        M.FalseInterfaces = R.FalseInterfaces;
        M.FalseExclusions = R.FalseExclusions;
        // True-branch: could be constant true or R true → no useful info.
      }
      if (!M.matched())
        return {};
      return M;
    }

    // Both non-constant: OneOf merge.
    TraceResult T = traceToCheckInstanceof(TrueVal, QueryObj, Visited, DT);
    if (!T.matched())
      return {}; // True arm doesn't trace — no match.
    TraceResult F = traceToCheckInstanceof(FalseVal, QueryObj, Visited, DT);
    if (!F.matched())
      return {}; // False arm doesn't trace — no match.
    TraceResult M;
    M.TrueKlass = computeLCA(T.TrueKlass, F.TrueKlass);
    M.TrueInterfaces = commonInterfaces(T.TrueInterfaces, F.TrueInterfaces);
    M.TrueExclusions =
        intersectExcludedKlasses(T.TrueExclusions, F.TrueExclusions);
    M.FalseKlass = computeLCA(T.FalseKlass, F.FalseKlass);
    M.FalseInterfaces = commonInterfaces(T.FalseInterfaces, F.FalseInterfaces);
    M.FalseExclusions =
        intersectExcludedKlasses(T.FalseExclusions, F.FalseExclusions);
    if (!M.matched())
      return {};
    return M;
  }

  // --- PHI: merge non-constant incomings with OneOf semantics ---
  // Don't know which incoming was selected → LCA for klass, intersect for
  // exclusions, on both branches.
  if (auto *PN = dyn_cast<PHINode>(Cond)) {
    TraceResult M;
    bool HaveMatch = false;
    bool HasConstantFalse = false;
    bool HasConstantTrue = false;

    for (unsigned I = 0, E = PN->getNumIncomingValues(); I != E; ++I) {
      Value *Inc = PN->getIncomingValue(I);

      // If the incoming block is dominated by a null-check edge (obj IS null
      // there), the arm is only live for the null execution, where type
      // facts conditioned on non-null are meaningless — skip it regardless
      // of whether the incoming is a constant.
      if (isNullCheckPath(PN->getIncomingBlock(I), QueryObj, DT))
        continue;

      if (auto *CI = dyn_cast<ConstantInt>(Inc)) {
        if (CI->isZero()) {
          // Constant false from non-null-check origin: on the true-branch
          // this path can't be taken (safe to skip), but on the false-branch
          // it could have been taken without any type check.
          HasConstantFalse = true;
          continue;
        }
        // Constant true from non-null-check origin: on the false-branch
        // this path can't be taken (safe to skip), but on the true-branch
        // it could have been taken without any type check.
        HasConstantTrue = true;
        continue;
      }

      // Non-constant incoming: must trace to a check_instanceof.
      TraceResult R = traceToCheckInstanceof(Inc, QueryObj, Visited, DT);
      if (!R.matched())
        return {}; // This incoming doesn't trace to a check — no match.
      if (!HaveMatch) {
        M = R;
        HaveMatch = true;
      } else {
        // OneOf merge: LCA for klass, intersect for exclusions.
        M.TrueKlass = computeLCA(M.TrueKlass, R.TrueKlass);
        M.TrueInterfaces = commonInterfaces(M.TrueInterfaces, R.TrueInterfaces);
        M.TrueExclusions =
            intersectExcludedKlasses(M.TrueExclusions, R.TrueExclusions);
        M.FalseKlass = computeLCA(M.FalseKlass, R.FalseKlass);
        M.FalseInterfaces =
            commonInterfaces(M.FalseInterfaces, R.FalseInterfaces);
        M.FalseExclusions =
            intersectExcludedKlasses(M.FalseExclusions, R.FalseExclusions);
      }
    }

    // Invalidate branch info that is unsound due to constant incomings
    // from non-null-check paths.
    if (HaveMatch) {
      if (HasConstantFalse) {
        M.FalseKlass = 0;
        M.FalseInterfaces.clear();
        M.FalseExclusions.clear();
      }
      if (HasConstantTrue) {
        M.TrueKlass = 0;
        M.TrueInterfaces.clear();
        M.TrueExclusions.clear();
      }
    }
    if (HaveMatch && M.matched())
      return M;
    return {}; // No non-constant incomings (all were skipped) — no match.
  }

  return {}; // Unrecognized value kind — no match.
}

// =============================================================================
// Edge-semantics dataflow engine
// =============================================================================
//
// Context-sensitive JavaType facts are computed by a demand-driven backward
// evaluation over CFG edges instead of a dominator-chain walk. Guards attach
// to the edges whose outcome they prove, path composition narrows (meets)
// facts along predecessor chains, and merges join (typeUnion) the per-edge
// contributions:
//
//   factsAt(V, B) = JOIN over non-skipped predecessors P of B:
//                     factsAt(V, P) [mergePathFacts] edgeGuard(P -> B, V)
//   sharpen(V, Ctx, DestBB)
//                 = factsAt(V, CtxBB) [mergePathFacts] edgeGuard(CtxBB ->
//                 DestBB, V)
//   getJavaType(V, DT, Ctx)
//                 = baseType(V) [typeIntersect] factsAt(V, CtxBB)
//   phiValueType(PN) = JOIN over incoming edges i:
//                     (base+path facts of incoming_i) [mergePathFacts]
//                     edgeGuard(P_i -> parent(PN), incoming_i)
//
// The two edge filters lose no information (they are exact, not approximate):
//
// - Back-edge skip: facts about an SSA oop are path-persistent — the value is
//   never redefined and the referent's klass is immutable, so a guard that
//   held on first arrival at B keeps holding for later arrivals. First arrival
//   at B never traverses an edge from a block that B dominates, so back edges
//   add nothing beyond what the non-back edges already contribute. (Cycles the
//   back-edge rule cannot cut — irreducible CFGs — are cut conservatively by
//   the in-progress fuse: an empty contribution to that join arm.)
//
// - Null-edge exclusion: JavaType is conditioned on a non-null oop (see
//   JavaType.h). An edge on which V is proven null carries no non-null type
//   constraint, and every dynamic execution in which V is non-null at B
//   arrives via a non-null edge, so unioning the remaining edges covers all
//   contract-valid executions. Skipping an *unproven* edge would be unsound
//   (it would strengthen the join without proof), hence a positive two-layer
//   proof: a structural fast path recognizing a branch/switch on
//   `icmp eq/ne V, null` directly feeding the edge, then an optional
//   null-edge oracle (backed by LazyValueInfo in CFG-stable passes) for
//   threaded/indirect forms.
//
// The seed cut at V's definition block is exact too: a branch condition
// referencing V is dominated by V's definition, so an edge into the definition
// block carrying facts about V would come from a dominated predecessor — a
// back edge, which is skipped anyway.
//
// Precision: a guard whose outgoing edge dominates the context block lies on
// every path from the function entry to the context, hence inside every path
// term of the join above, and typeUnion preserves consequences common to all
// paths — such guards are always recovered. Merges where no single edge
// dominates the context are additionally recovered: each arm's edge guard
// contributes to its own path term, and the join keeps exactly the common
// consequences.
//
// Determinism (VM callback record/replay contract, VMCallback.h): predecessor
// iteration follows pred_begin (use-list) order; the memo and in-progress
// sets are keyed by (Value*, BasicBlock*) and are only looked up, inserted and
// erased, never iterated; results are memoized per top-level query and only
// once complete — budget-exhausted frames contribute {} without being cached.
//
// Known limitations: a boolean-phi-carried check whose empty blocks were
// folded but whose edges were not threaded (the information then lives only
// in the phi's value semantics); all-null-edge merges (JavaType cannot
// represent "known null"); irreducible CFGs (conservative via the fuse); the
// per-query join budget (deeper single-predecessor chains conservatively
// return unknown).

/// Maximum number of joined blocks per top-level query, per dimension (the
/// block dimension and the PHI-value dimension each get their own allowance,
/// so consuming one does not silently starve the other). Bounds compile time;
/// exceeding frames contribute an empty (unknown) fact and are not memoized.
/// Hidden tuning knob: large methods with joins deeper than the default lose
/// check-derived sharpening (sound, precision-only) and can raise this.
static cl::opt<unsigned> MaxFactsJoinBlocks(
    "jeandle-max-facts-join-blocks", cl::init(128), cl::Hidden,
    cl::desc("Maximum joined blocks per JavaType query dimension"));

namespace {

/// Per-query evaluation state. Facts depend only on the CFG, branch
/// conditions, the null-edge oracle and VM callbacks, so they are constant
/// for the lifetime of one query and safely memoized here.
///
/// The memo's lifetime is deliberately one top-level query, not one pass:
/// within a query it turns the exponential path join into a linear one, while
/// consumers amortize across queries with their own result caches
/// (RecoverTypeInfo's per-load and per-edge caches). A pass-scoped memo would
/// additionally need invalidation discipline for every consumer that erases
/// instructions mid-pass (ConstantFieldFolding does), where dangling Value*
/// keys could alias freshly allocated values and return stale facts.
struct JavaTypeQueryContext {
  DominatorTree &DT;
  IsNullEdgeOracle NullOracle;
  /// Shared PHI cycle-detection set for the value dimension (base-type PHI
  /// handling and phiValueType): a re-encountered PHI contributes nothing.
  SmallPtrSet<const PHINode *, 8> PhiVisited;
  /// Complete base-type memo shared across the whole query (see BaseMemo).
  BaseMemo BaseTypes;
  /// Per-(value, block) evaluation state for the block dimension: absent =
  /// not yet evaluated, nullopt = currently on the evaluation stack (a cycle
  /// the back-edge rule cannot cut), engaged = the completed join. One
  /// container for both memoization and cycle detection keeps the two from
  /// drifting apart across exit paths.
  DenseMap<std::pair<Value *, BasicBlock *>, std::optional<JavaType>> Processed;
  unsigned FactsBudget = MaxFactsJoinBlocks;
  unsigned PhiBudget = MaxFactsJoinBlocks;
};

} // namespace

/// Narrow-only path composition: merge guard facts G into the accumulated path
/// facts Acc. A more specific positive klass replaces the accumulated one; an
/// unrelated or less specific one is dropped (never widened into an LCA — two
/// simultaneous guards on one path both hold, and an LCA would weaken them;
/// dropping preserves the established fact). Interfaces accumulate; exclusions
/// merge subtype-aware. This deliberately is not typeIntersect: intersecting
/// two unrelated non-exact guards (e.g. two interface checks) would drop the
/// positive klass to 0 and lose isKnown(). Semantic changes to the klass
/// ladder below should be mirrored against typeIntersect's ladder (equal
/// klass, one-side-exact, subtype narrowing) — the two must stay consistent
/// in the cases they share.
static void mergePathFacts(JavaType &Acc, const JavaType &G) {
  if (G.Klass != 0) {
    if (!Acc.isKnown()) {
      Acc.Klass = G.Klass;
      Acc.Exact = G.Exact;
    } else if (G.Klass == Acc.Klass) {
      // Both constraints name the same klass; an exact claim ("exactly this
      // class") subsumes an instanceof claim, so exactness is disjunctive.
      // This keeps a base-derived Exact=true (allocation type, exact
      // metadata, constant oop) when a guard only proves instanceof(K).
      Acc.Exact = Acc.Exact || G.Exact;
    } else if (getVMCallbacks()->IsSubtype(G.Klass, Acc.Klass)) {
      Acc.Klass = G.Klass;
      Acc.Exact = G.Exact;
    }
  }
  Acc.Interfaces.insert(G.Interfaces.begin(), G.Interfaces.end());
  unionExcludedKlasses(Acc.ExcludedKlasses, G.ExcludedKlasses);
}

/// Convert one side of a TraceResult to facts-only JavaType form. Exact is a
/// pure function of the klass (IsEffectivelyFinal).
static JavaType
traceSideToFacts(uintptr_t Klass, const SmallDenseSet<uintptr_t, 2> &Interfaces,
                 const SmallDenseSet<uintptr_t, 2> &Exclusions) {
  JavaType Facts;
  if (Klass != 0) {
    const VMCallbacks *CB = getVMCallbacks();
    assert(CB && CB->IsEffectivelyFinal && "IsEffectivelyFinal must be set");
    Facts.Klass = Klass;
    Facts.Exact = CB->IsEffectivelyFinal(Klass);
  }
  Facts.Interfaces.insert(Interfaces.begin(), Interfaces.end());
  unionExcludedKlasses(Facts.ExcludedKlasses, Exclusions);
  return Facts;
}

/// The guard that edge From -> To implies about V: if exactly one successor of
/// From's conditional branch is To, that outcome's constraints held along the
/// edge. A duplicate edge (both successors are To) carries no outcome
/// information. Non-branch terminators carry no guard.
static JavaType edgeGuard(BasicBlock *From, BasicBlock *To, Value *V,
                          DominatorTree &DT) {
  auto *BI = dyn_cast<BranchInst>(From->getTerminator());
  if (!BI || !BI->isConditional())
    return {};

  V = V->stripPointerCastsAndAliases();
  BasicBlock *TrueBB = BI->getSuccessor(0);
  BasicBlock *FalseBB = BI->getSuccessor(1);
  bool TrueIsTo = (TrueBB == To);
  bool FalseIsTo = (FalseBB == To);
  if (TrueIsTo == FalseIsTo)
    return {};

  // Exact-klass guard fast path. A failed exact-class guard does not imply
  // that the object is not an instance of the guarded class: it may still be
  // a subclass, so the false side contributes nothing.
  if (uintptr_t Exact = traceExactKlassGuard(BI->getCondition(), V)) {
    if (TrueIsTo) {
      LLVM_DEBUG(dbgs() << "JavaType: edge guard " << From->getName() << " -> "
                        << To->getName() << " proves exact klass " << Exact
                        << " for " << *V << "\n");
      return JavaType(Exact, /*Exact=*/true);
    }
    return {};
  }

  SmallPtrSet<Value *, 16> TraceVisited;
  TraceResult TR =
      traceToCheckInstanceof(BI->getCondition(), V, TraceVisited, DT);
  if (!TR.matched())
    return {};

  LLVM_DEBUG(dbgs() << "JavaType: edge guard " << From->getName() << " -> "
                    << To->getName() << " constrains " << *V << "\n");
  if (TrueIsTo)
    return traceSideToFacts(TR.TrueKlass, TR.TrueInterfaces, TR.TrueExclusions);
  return traceSideToFacts(TR.FalseKlass, TR.FalseInterfaces,
                          TR.FalseExclusions);
}

/// Positive proof that V is null on edge From -> To, answered by the query's
/// null-edge oracle (the LazyValueInfo-backed implementation recognizes null
/// tests directly on the edge's branch as well as threaded/indirect forms).
/// When in doubt the oracle answers false — keeping an edge is always sound.
static bool isNullEdge(Value *V, BasicBlock *From, BasicBlock *To,
                       const JavaTypeQueryContext &Q) {
  if (!Q.DT.isReachableFromEntry(From))
    return false; // Lattice reasoning is undefined for unreachable blocks;
                  // keep the edge (the conservative answer).
  return Q.NullOracle && Q.NullOracle(V, From, To);
}

/// Facts holding about V at the top of BB: the join over non-skipped incoming
/// edges of (facts at the predecessor, narrowed by the edge guard).
/// Facts-only: check-derived constraints, never attribute/metadata base types.
static JavaType factsAt(Value *V, BasicBlock *BB, JavaTypeQueryContext &Q) {
  V = stripCastsAndFreeze(V);

  // Seed cuts (exact, see the design comment above).
  if (BB->isEntryBlock())
    return {};
  if (auto *I = dyn_cast<Instruction>(V))
    if (I->getParent() == BB)
      return {}; // Definition block: only back edges could reference V here.
  if (!Q.DT.isReachableFromEntry(BB))
    return {}; // Dominance is undefined for unreachable blocks.

  auto Key = std::make_pair(V, BB);
  auto [It, Inserted] = Q.Processed.try_emplace(Key);
  if (!Inserted) {
    if (It->second)
      return *It->second;
    return {}; // On the evaluation stack: a cycle the back-edge rule cannot
               // cut (irreducible) — empty contribution to that join arm.
  }
  if (Q.FactsBudget == 0) {
    ++NumJavaTypeBudgetExhausted;
    LLVM_DEBUG(dbgs() << "JavaType: per-query block budget exhausted at "
                      << BB->getName() << " for " << *V << "\n");
    Q.Processed.erase(It);
    return {}; // Budget exhausted — deliberately not memoized.
  }
  --Q.FactsBudget;

  JavaType Joined;
  bool First = true;
  for (BasicBlock *P : predecessors(BB)) {
    if (Q.DT.dominates(BB, P))
      continue; // Back edge (exact, see the design comment).
    if (isNullEdge(V, P, BB, Q))
      continue; // Null edge (exact, see the design comment).
    JavaType E = factsAt(V, P, Q);
    mergePathFacts(E, edgeGuard(P, BB, V, Q.DT));
    joinArm(Joined, First, std::move(E));
  }

  // The join loop above recursed through factsAt, which may have rehashed
  // Processed and invalidated It — re-look the slot up by key.
  JavaType Result = std::move(Joined);
  Q.Processed[Key] = Result;
  return Result;
}

/// Value dimension for PHIs: the join over incoming edges of each incoming
/// value's full type at that edge (its own base/facts, narrowed by the guard
/// on the incoming edge). Cycle discipline: an incoming PHI is skipped only
/// while it is on the current recursion stack (PhiVisited is a stack, erased
/// on exit) — skipping a merely-visited PHI would drop it from the join and
/// narrow the result unsoundly when the same PHI feeds two different arms.
/// Any remaining unknown incoming bails the whole PHI to unknown, and
/// incomings arriving on proven-null edges are skipped (they carry no
/// non-null type constraint under the non-null contract).
static JavaType valueDimension(Value *V, JavaTypeQueryContext &Q);

static JavaType phiValueType(PHINode *PN, JavaTypeQueryContext &Q) {
  if (!Q.PhiVisited.insert(PN).second)
    return {}; // Cycle detected — caller will skip this incoming.
  auto StackGuard = make_scope_exit([&]() { Q.PhiVisited.erase(PN); });
  if (Q.PhiBudget == 0) {
    ++NumJavaTypeBudgetExhausted;
    LLVM_DEBUG(dbgs() << "JavaType: per-query PHI budget exhausted entering "
                      << *PN << "\n");
    return {}; // PHI frames count against the value dimension's budget.
  }
  --Q.PhiBudget;

  JavaType Result;
  bool First = true;
  for (unsigned I = 0, E = PN->getNumIncomingValues(); I != E; ++I) {
    Value *Inc = PN->getIncomingValue(I);
    BasicBlock *IncBB = PN->getIncomingBlock(I);

    // Skip a PHI incoming we have already visited (cycle); the PHI's type is
    // determined by the values entering the cycle, which are exactly the
    // non-cyclic incomings.
    if (auto *IncPN = dyn_cast<PHINode>(Inc))
      if (Q.PhiVisited.count(IncPN))
        continue;

    if (isNullEdge(Inc, IncBB, PN->getParent(), Q))
      continue;

    JavaType T = valueDimension(Inc, Q);
    T = typeIntersect(T, factsAt(Inc, IncBB, Q));
    mergePathFacts(T, edgeGuard(IncBB, PN->getParent(), Inc, Q.DT));
    if (T.isUnknown())
      return {};
    joinArm(Result, First, std::move(T));
    if (Result.isUnknown())
      return {};
  }
  return Result;
}

/// The value dimension of a query: the full type of V itself — the PHI value
/// dimension for PHI nodes, the context-insensitive base type otherwise
/// (shared BaseMemo across the whole query).
static JavaType valueDimension(Value *V, JavaTypeQueryContext &Q) {
  if (auto *PN = dyn_cast<PHINode>(V))
    return phiValueType(PN, Q);
  // Fresh recursion stack, deliberately not Q.PhiVisited: the IsRoot memo
  // exemption (see BaseMemo) is only sound when every truncation the root
  // computation sees is a back edge of its own recursion. Sharing the value
  // dimension's stack would let an outer phiValueType frame be mistaken for
  // a cycle, silently dropping a live incoming and caching the too-narrow
  // result.
  SmallPtrSet<const PHINode *, 8> BaseStack;
  return getBaseJavaType(V, BaseStack, &Q.BaseTypes);
}

JavaType jeandle::sharpen(Value *V, Instruction *Context, DominatorTree &DT,
                          BasicBlock *DestBB, IsNullEdgeOracle IsNullEdge) {
  assert(getVMCallbacks() && getVMCallbacks()->IsSubtype &&
         "VMCallbacks must be set");

  V = stripCastsAndFreeze(V);
  JavaTypeQueryContext Q{DT, IsNullEdge};
  JavaType Facts = factsAt(V, Context->getParent(), Q);
  mergePathFacts(Facts, edgeGuard(Context->getParent(), DestBB, V, DT));
  normalizeExcludedKlasses(Facts);
  return Facts;
}

// =============================================================================
// Main query
// =============================================================================

JavaType jeandle::getJavaType(Value *V, DominatorTree *DT, Instruction *Context,
                              IsNullEdgeOracle IsNullEdge) {
  // Strip pointer casts (and freeze wrappers) at the API boundary so that
  // downstream identity comparisons (traceToCheckInstanceof, isNullCheckPath,
  // isNullEdge) work correctly even when optimization passes introduce
  // bitcast/addrspacecast/freeze wrappers.
  V = stripCastsAndFreeze(V);

  if (!DT || !Context) {
    SmallPtrSet<const PHINode *, 8> Visited;
    return getBaseJavaType(V, Visited);
  }

  JavaTypeQueryContext Q{*DT, IsNullEdge};
  JavaType T = valueDimension(V, Q);
  return typeIntersect(T, factsAt(V, Context->getParent(), Q));
}
