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
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Jeandle/JeandleUtils.hpp"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/Support/Debug.h"

#define DEBUG_TYPE "java-type"

using namespace llvm;
using namespace llvm::jeandle;

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

JavaType jeandle::typeUnion(JavaType A, JavaType B) {
  if (A.Klass == 0 && B.Klass == 0) {
    // Both have unknown positive type. Intersect exclusions.
    JavaType Result;
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
    JavaType Result;
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
  JavaType Result;
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

  // Positive type: pick the more specific one.
  if (A.isKnown() && B.isKnown()) {
    const VMCallbacks *CB = getVMCallbacks();
    assert(CB && CB->IsSubtype && "VMCallbacks must be set");
    if (CB->IsSubtype(A.Klass, B.Klass)) {
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

// No exclusions during context-insensitive type query.
static JavaType getBaseJavaType(Value *V,
                                SmallPtrSetImpl<const PHINode *> &Visited) {
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
        if (uintptr_t Klass = CB->GetOopKlass(*Id); Klass != 0)
          return {Klass, /*Exact=*/true};
      }
    }
    return {};
  }

  // PHI: compute LCA of all incoming values.
  // For cycles (loop back-edges): when an incoming is a PHI already in the
  // visited set, skip it. The type is determined by the non-cyclic incomings.
  if (auto *PN = dyn_cast<PHINode>(V)) {
    if (!Visited.insert(PN).second)
      return {}; // Cycle detected — caller will skip this incoming.
    JavaType Result;
    bool First = true;
    for (unsigned I = 0, E = PN->getNumIncomingValues(); I != E; ++I) {
      Value *Inc = PN->getIncomingValue(I);
      if (auto *IncPN = dyn_cast<PHINode>(Inc)) {
        if (Visited.count(IncPN))
          continue; // Skip cyclic incoming.
      }
      // JavaType does not model nullability. Any positive facts derived from
      // jeandle.check_instanceof remain sound here only because current
      // consumers query it under check_instanceof's non-null oop contract.
      JavaType IncType = getBaseJavaType(Inc, Visited);
      if (IncType.isUnknown())
        return {};
      if (First) {
        Result = IncType;
        First = false;
      } else {
        Result = typeUnion(Result, IncType);
        if (Result.isUnknown())
          return {};
      }
    }
    return Result;
  }

  // Select: LCA of both operands.
  if (auto *SI = dyn_cast<SelectInst>(V)) {
    JavaType TrueType = getBaseJavaType(SI->getTrueValue(), Visited);
    if (TrueType.isUnknown())
      return {};
    JavaType FalseType = getBaseJavaType(SI->getFalseValue(), Visited);
    return typeUnion(TrueType, FalseType);
  }

  // BitCast / AddrSpaceCast / Freeze: pass through.
  if (auto *BC = dyn_cast<BitCastInst>(V))
    return getBaseJavaType(BC->getOperand(0), Visited);
  if (auto *ASC = dyn_cast<AddrSpaceCastInst>(V))
    return getBaseJavaType(ASC->getOperand(0), Visited);
  if (auto *FI = dyn_cast<FreezeInst>(V))
    return getBaseJavaType(FI->getOperand(0), Visited);

  return {};
}

// =============================================================================
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
  SmallDenseSet<uintptr_t, 2> TrueExclusions;
  uintptr_t FalseKlass = 0;
  SmallDenseSet<uintptr_t, 2> FalseExclusions;

  bool matched() const {
    return TrueKlass != 0 || !TrueExclusions.empty() || FalseKlass != 0 ||
           !FalseExclusions.empty();
  }
};

} // anonymous namespace

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

/// Check if IncomingBB is reached only when Obj is null.
/// Walks up the dominator tree from IncomingBB looking for a conditional branch
/// on `icmp eq/ne Obj, null` where IncomingBB is dominated by the "Obj is null"
/// successor. Using the dominator tree handles all CFG shapes (diamonds, etc.),
/// not just single-predecessor chains.
static bool isNullCheckPath(BasicBlock *IncomingBB, Value *Obj,
                            DominatorTree &DT) {
  Obj = Obj->stripPointerCastsAndAliases();
  for (auto *Node = DT.getNode(IncomingBB); Node; Node = Node->getIDom()) {
    BasicBlock *BB = Node->getBlock();

    // --- BranchInst: check `icmp eq/ne Obj, null` ---
    if (auto *BI = dyn_cast<BranchInst>(BB->getTerminator())) {
      if (!BI->isConditional())
        continue;

      auto *Cmp = dyn_cast<ICmpInst>(BI->getCondition());
      if (!Cmp)
        continue;

      // Check if condition is `icmp eq/ne Obj, null`.
      Value *LHS = Cmp->getOperand(0);
      Value *RHS = Cmp->getOperand(1);
      bool LHSNull = isa<ConstantPointerNull>(LHS);
      bool RHSNull = isa<ConstantPointerNull>(RHS);
      Value *Tested = LHSNull ? RHS : (RHSNull ? LHS : nullptr);
      if (!Tested || Tested->stripPointerCastsAndAliases() != Obj)
        continue;

      // Determine which successor means "Obj is null".
      // icmp eq Obj, null → true successor = null path
      // icmp ne Obj, null → false successor = null path
      BasicBlock *NullBB = nullptr;
      if (Cmp->getPredicate() == ICmpInst::ICMP_EQ)
        NullBB = BI->getSuccessor(0);
      else if (Cmp->getPredicate() == ICmpInst::ICMP_NE)
        NullBB = BI->getSuccessor(1);
      else
        continue;

      // IncomingBB must be dominated by the null-path edge.
      BasicBlockEdge NullEdge(BB, NullBB);
      if (DT.dominates(NullEdge, IncomingBB))
        return true;
      continue;
    }

    // --- SwitchInst: check `switch Obj [... case null: ...]` ---
    if (auto *SI = dyn_cast<SwitchInst>(BB->getTerminator())) {
      Value *Cond = SI->getCondition();
      if (Cond->stripPointerCastsAndAliases() != Obj)
        continue;

      // Find the null case.
      BasicBlock *NullBB = nullptr;
      for (auto &Case : SI->cases()) {
        if (isa<ConstantPointerNull>(Case.getCaseValue())) {
          NullBB = Case.getCaseSuccessor();
          break;
        }
      }
      if (!NullBB)
        continue;

      BasicBlockEdge NullEdge(BB, NullBB);
      if (DT.dominates(NullEdge, IncomingBB))
        return true;
      continue;
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
      R.TrueKlass = Klass;             // check passed → obj IS Klass
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
        M.TrueExclusions = L.TrueExclusions;
        unionExcludedKlasses(M.TrueExclusions, R.TrueExclusions);
        // False-branch: at least one of L, R is false → OneOf.
        M.FalseKlass = computeLCA(L.FalseKlass, R.FalseKlass);
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
        M.TrueExclusions = L.TrueExclusions;
        return M;
      }
      if (R.matched()) {
        TraceResult M;
        M.TrueKlass = R.TrueKlass;
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
        M.TrueExclusions =
            intersectExcludedKlasses(L.TrueExclusions, R.TrueExclusions);
        // False-branch: both L and R are false → AllOf.
        M.FalseKlass = pickMostSpecific(L.FalseKlass, R.FalseKlass);
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
        M.FalseExclusions = L.FalseExclusions;
        return M;
      }
      if (R.matched()) {
        TraceResult M;
        M.FalseKlass = R.FalseKlass;
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
        M.TrueExclusions = R.TrueExclusions;
        // False-branch: could be constant false or R false → no useful info.
      } else {
        // Constant true: on the select's false-branch, the constant arm can't
        // be selected → the non-constant arm was selected and is false.
        M.FalseKlass = R.FalseKlass;
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
    M.TrueExclusions =
        intersectExcludedKlasses(T.TrueExclusions, F.TrueExclusions);
    M.FalseKlass = computeLCA(T.FalseKlass, F.FalseKlass);
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

      if (auto *CI = dyn_cast<ConstantInt>(Inc)) {
        // If the incoming is from a null-check path (obj IS null), type info
        // is meaningless regardless of the constant value — safe to skip on
        // both branches.
        if (isNullCheckPath(PN->getIncomingBlock(I), QueryObj, DT))
          continue;

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
        M.TrueExclusions =
            intersectExcludedKlasses(M.TrueExclusions, R.TrueExclusions);
        M.FalseKlass = computeLCA(M.FalseKlass, R.FalseKlass);
        M.FalseExclusions =
            intersectExcludedKlasses(M.FalseExclusions, R.FalseExclusions);
      }
    }

    // Invalidate branch info that is unsound due to constant incomings
    // from non-null-check paths.
    if (HaveMatch) {
      if (HasConstantFalse) {
        M.FalseKlass = 0;
        M.FalseExclusions.clear();
      }
      if (HasConstantTrue) {
        M.TrueKlass = 0;
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
// Context-sensitive sharpening
// =============================================================================

/// DestBB: for PHI incoming processing, the PHI's parent block. When provided,
/// the incoming block's own branch is considered for sharpening (the branch
/// targets DestBB, so it should be considered to sharpen the PHI's type).
/// For non-PHI contexts, DestBB is nullptr and the context block's own branch
/// is skipped.
static JavaType sharpenFromDominators(Value *V, Instruction *Context,
                                      DominatorTree &DT,
                                      BasicBlock *DestBB = nullptr) {
  const VMCallbacks *CB = getVMCallbacks();
  assert(CB && CB->IsSubtype && "VMCallbacks must be set");

  BasicBlock *ContextBB = Context->getParent();
  JavaType Best;

  for (auto *Node = DT.getNode(ContextBB); Node; Node = Node->getIDom()) {
    BasicBlock *BB = Node->getBlock();
    auto *BI = dyn_cast<BranchInst>(BB->getTerminator());
    if (!BI || !BI->isConditional())
      continue;

    // For ContextBB's own branch: skip unless DestBB is provided (PHI case).
    // The branch hasn't executed for non-PHI contexts, but for PHI incomings
    // the branch targets DestBB, so it should be considered for sharpening.
    if (BB == ContextBB && !DestBB)
      continue;

    SmallPtrSet<Value *, 16> TraceVisited;
    TraceResult TR =
        traceToCheckInstanceof(BI->getCondition(), V, TraceVisited, DT);
    if (!TR.matched())
      continue;

    BasicBlock *TrueBB = BI->getSuccessor(0);
    BasicBlock *FalseBB = BI->getSuccessor(1);

    // For ContextBB's own branch, check against DestBB (the PHI's block).
    // For dominator blocks above ContextBB, check against ContextBB as before.
    BasicBlock *CheckBB = (BB == ContextBB) ? DestBB : ContextBB;

    // Apply constraints from whichever branch edge dominates the context.
    // Block dominance alone (DT.dominates(SuccBB, CheckBB)) is insufficient:
    // SuccBB might be reachable from both edges of the branch if it has
    // multiple predecessors. Use edge dominance via BasicBlockEdge, which
    // correctly handles loop back-edges and multi-predecessor successors.
    BasicBlockEdge TrueEdge(BB, TrueBB);
    BasicBlockEdge FalseEdge(BB, FalseBB);
    uintptr_t Klass = 0;
    const SmallDenseSet<uintptr_t, 2> *Exclusions = nullptr;
    if (DT.dominates(TrueEdge, CheckBB)) {
      Klass = TR.TrueKlass;
      Exclusions = &TR.TrueExclusions;
    } else if (DT.dominates(FalseEdge, CheckBB)) {
      Klass = TR.FalseKlass;
      Exclusions = &TR.FalseExclusions;
    }

    if (Klass != 0) {
      LLVM_DEBUG(dbgs() << "JavaType: sharpened " << *V << " to klass " << Klass
                        << " from dominating check in " << BB->getName()
                        << "\n");
      assert(CB->IsEffectivelyFinal && "IsEffectivelyFinal must be set");
      bool IsExact = CB->IsEffectivelyFinal(Klass);
      if (!Best.isKnown()) {
        Best.Klass = Klass;
        Best.Exact = IsExact;
      } else if (CB->IsSubtype(Klass, Best.Klass)) {
        Best.Klass = Klass;
        Best.Exact = IsExact;
      }
    }
    if (Exclusions) {
      for (uintptr_t K : *Exclusions) {
        LLVM_DEBUG(dbgs() << "JavaType: excluded " << *V << " from klass " << K
                          << " from dominating check in " << BB->getName()
                          << "\n");
        addExcludedKlass(Best.ExcludedKlasses, K);
      }
    }
  }

  normalizeExcludedKlasses(Best);
  return Best;
}

// =============================================================================
// Main query
// =============================================================================

static JavaType getJavaTypeImpl(Value *V, DominatorTree &DT,
                                Instruction *Context,
                                SmallPtrSetImpl<const PHINode *> &Visited,
                                BasicBlock *DestBB = nullptr);

/// Context-sensitive PHI handling: query each incoming with its own context.
/// For PHI cycles (loop back-edges): when we re-encounter a PHI already in the
/// visited set, we skip that incoming. The type is determined only by the
/// non-cyclic incomings. This is sound because a loop PHI's type is the LCA of
/// all values entering the cycle, which are exactly the non-cyclic incomings.
static JavaType getPhiJavaType(PHINode *PN, DominatorTree &DT,
                               SmallPtrSetImpl<const PHINode *> &Visited) {
  if (!Visited.insert(PN).second)
    return {}; // Cycle detected — caller will skip this incoming.

  JavaType Result;
  bool First = true;
  for (unsigned I = 0, E = PN->getNumIncomingValues(); I != E; ++I) {
    Value *Inc = PN->getIncomingValue(I);
    BasicBlock *IncBB = PN->getIncomingBlock(I);
    Instruction *IncContext = IncBB->getTerminator();

    // Check if the incoming is a PHI we've already visited (cycle).
    // If so, skip it — the type from this path will be determined by the
    // non-cyclic incomings.
    if (auto *IncPN = dyn_cast<PHINode>(Inc)) {
      if (Visited.count(IncPN))
        continue;
    }

    JavaType IncType =
        getJavaTypeImpl(Inc, DT, IncContext, Visited, PN->getParent());
    if (IncType.isUnknown())
      return {};
    if (First) {
      Result = IncType;
      First = false;
    } else {
      Result = typeUnion(Result, IncType);
      if (Result.isUnknown())
        return {};
    }
  }
  return Result;
}

static JavaType getJavaTypeImpl(Value *V, DominatorTree &DT,
                                Instruction *Context,
                                SmallPtrSetImpl<const PHINode *> &Visited,
                                BasicBlock *DestBB) {
  // Context-sensitive PHI handling: compute per-incoming types via
  // getPhiJavaType, then also sharpen from dominators of the Context.
  // The PHI's incoming analysis gives the base type; dominator checks at
  // the use site (Context) can further narrow it.
  if (auto *PN = dyn_cast<PHINode>(V)) {
    if (Context) {
      JavaType PhiType = getPhiJavaType(PN, DT, Visited);
      JavaType Sharpened = sharpenFromDominators(V, Context, DT, DestBB);
      return typeIntersect(PhiType, Sharpened);
    }
  }

  // Get base type (context-insensitive).
  JavaType Base = getBaseJavaType(V, Visited);

  // Context-sensitive sharpening: intersect with dominator-derived constraints.
  if (Context) {
    JavaType Sharpened = sharpenFromDominators(V, Context, DT, DestBB);
    Base = typeIntersect(Base, Sharpened);
  }

  return Base;
}

JavaType jeandle::getJavaType(Value *V, DominatorTree *DT,
                              Instruction *Context) {
  // Strip pointer casts at the API boundary so that downstream identity
  // comparisons (traceToCheckInstanceof, isNullCheckPath) work correctly
  // even when optimization passes introduce bitcast/addrspacecast wrappers.
  V = V->stripPointerCastsAndAliases();

  SmallPtrSet<const PHINode *, 8> Visited;
  if (DT)
    return getJavaTypeImpl(V, *DT, Context, Visited);
  return getBaseJavaType(V, Visited);
}
