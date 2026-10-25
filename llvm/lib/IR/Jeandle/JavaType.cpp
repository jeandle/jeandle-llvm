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
#include "llvm/ADT/APInt.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/ScopeExit.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/Statistic.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/GlobalAlias.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Jeandle/JeandleUtils.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Operator.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Debug.h"
#include <algorithm>
#include <cstdint>
#include <memory>

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

/// Pointer wrappers do not establish which definition supplies an interposable
/// alias. Only aliases with a definitive local target may be followed.
static Value *stripKlassPointerWrappers(Value *V) {
  SmallPtrSet<Value *, 8> Visited;
  while (Visited.insert(V).second) {
    V = V->stripPointerCasts();
    auto *Alias = dyn_cast<GlobalAlias>(V);
    if (!Alias || Alias->isInterposable())
      return V;
    V = Alias->getAliasee();
  }
  return V;
}

static uintptr_t extractKlassConstantImpl(Value *V, unsigned Depth) {
  if (Depth > MaxExtractKlassDepth)
    return 0;

  // A freeze preserves its operand's Klass only when the operand is defined.
  if (auto *FI = dyn_cast<FreezeInst>(V))
    return isProvenDefined(FI->getOperand(0))
               ? extractKlassConstantImpl(FI->getOperand(0), Depth + 1)
               : 0;

  // Strip pointer casts (bitcast, addrspacecast, zero-index GEP) and
  // aliases to see through wrappers that optimization passes may introduce.
  V = stripKlassPointerWrappers(V);

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
            stripKlassPointerWrappers(LI->getPointerOperand()))) {
      if (GV->isConstant() && GV->hasDefinitiveInitializer())
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
  if (KlassExact)
    return true;
  if (CB->IsSubtype(OtherKlass, Klass) || CB->IsInterface(OtherKlass))
    return false;
  // Arrays of interfaces can overlap with unrelated array bounds through
  // covariant element subtypes. The verifier classification includes both
  // interfaces themselves and arrays with an interface base element.
  return CB->IsUnverifiedInterface && !CB->IsUnverifiedInterface(Klass) &&
         !CB->IsUnverifiedInterface(OtherKlass);
}

/// Return true if F is jeandle.check_instanceof.
static bool isCheckInstanceofFn(const Function *F) {
  return F && F->getName() == "jeandle.check_instanceof";
}

/// If CB is a call/invoke to jeandle.check_instanceof, return the super klass
/// and obj. The name match alone is not an identity: legal IR may declare a
/// same-named function with a different signature, so the operand accesses
/// are guarded by an arity check.
static bool isCheckInstanceofCall(const CallBase *CB, uintptr_t &Klass,
                                  Value *&Obj) {
  if (!isCheckInstanceofFn(CB->getCalledFunction()) || CB->arg_size() != 2)
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
/// 2. Remove exclusions already implied by an incompatible positive bound.
///    Interfaces and covariant arrays may overlap without either bound being
///    a subtype of the other, so absence of a subtype relation is insufficient.
static void normalizeExcludedKlasses(JavaType &T) {
  if (T.ExcludedKlasses.empty())
    return;
  if (T.Exact) {
    T.ExcludedKlasses.clear();
    return;
  }
  if (T.Klass != 0) {
    SmallVector<uintptr_t, 2> ToRemove;
    for (uintptr_t K : T.ExcludedKlasses) {
      if (areKlassesIncompatible(T.Klass, T.Exact, K))
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
    // No common superclass: the positive type is unknown, but the already
    // computed Interfaces intersection and the exclusion merge below remain
    // the honest join — they are not discarded. (HotSpot's LCA walk reaches
    // java.lang.Object from any pair, so this branch is defensive.)
    if (LCA == 0) {
      Result.Klass = 0;
      Result.Exact = false;
    } else {
      Result.Klass = LCA;
      Result.Exact = false;
    }
  }
  // An exclusion common to both arms can be explicit on one side and implied
  // by the positive bound on the other. Examine candidates from both arms.
  auto Excludes = [](const JavaType &T, uintptr_t K) {
    return isExcludedBy(K, T.ExcludedKlasses) ||
           (T.isKnown() && areKlassesIncompatible(T.Klass, T.Exact, K));
  };
  for (const JavaType *T : {&A, &B})
    for (uintptr_t K : T->ExcludedKlasses)
      if (Excludes(A, K) && Excludes(B, K))
        addExcludedKlass(Result.ExcludedKlasses, K);
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
    } else if (CB->IsInterface(A.Klass) != CB->IsInterface(B.Klass)) {
      // A concrete class bound and an unrelated interface can both hold for
      // a subclass. Preserve the class while Interfaces carries the other
      // constraint independently.
      Result.Klass = CB->IsInterface(A.Klass) ? B.Klass : A.Klass;
    }
    // Other unrelated bounds need not have a representable intersection;
    // retain their common interface constraints without inventing a Klass.
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

/// Complete context-insensitive types, independent of the query point.
/// An absorbing unknown input can complete a query early; other cyclic
/// dependencies are cached only after the whole SCC has been evaluated.
using BaseMemo = DenseMap<Value *, JavaType>;
using DefinedMemo = DenseMap<Value *, bool>;

/// Follow one pointer identity expression. Explicit type seeds are separate
/// constraints on the result, rather than a reason to discard this dependency.
Value *jeandle::getJavaIdentityInput(Value *V) {
  if (!V->getType()->isPointerTy())
    return nullptr;
  if (auto *GEP = dyn_cast<GEPOperator>(V))
    return GEP->hasAllZeroIndices() ? GEP->getPointerOperand() : nullptr;
  if (auto *Alias = dyn_cast<GlobalAlias>(V)) {
    // Pointer wrappers do not establish which definition supplies an
    // interposable alias (same rule as stripKlassPointerWrappers): only an
    // alias with a definitive target may forward the aliasee's type.
    return Alias->isInterposable() ? nullptr : Alias->getAliasee();
  }
  if (auto *CB = dyn_cast<CallBase>(V)) {
    if (CB->getIntrinsicID() == Intrinsic::launder_invariant_group ||
        CB->getIntrinsicID() == Intrinsic::strip_invariant_group)
      return CB->getArgOperand(0);
    return CB->getReturnedArgOperand();
  }
  if (Operator::getOpcode(V) == Instruction::BitCast ||
      Operator::getOpcode(V) == Instruction::AddrSpaceCast)
    return cast<User>(V)->getOperand(0);
  return nullptr;
}

/// The inputs whose types bound V. Identity expressions participate in the
/// same dependency graph as PHIs and selects, including when nested in cycles.
///
/// When SkipVacuousArms is set (type queries), literal null and poison PHI and
/// select arms are skipped: JavaType describes the value only when it is a
/// non-null oop, so an execution that would select such an arm is outside the
/// contract and the arm is vacuous. Undef arms are NOT skipped — an undef arm
/// can materialize an arbitrary oop when reached, so it must stay absorbing.
/// Definedness queries pass false: a null arm is defined and a poison arm is
/// not, and both facts matter there.
static bool getBaseTypeInputs(Value *V, SmallVectorImpl<Value *> &Inputs,
                              bool SkipVacuousArms) {
  auto SkipVacuous = [&](Value *Arm) {
    return SkipVacuousArms && isa<ConstantPointerNull, PoisonValue>(Arm);
  };
  if (auto *PN = dyn_cast<PHINode>(V)) {
    for (Value *Inc : PN->incoming_values())
      if (!SkipVacuous(Inc))
        Inputs.push_back(Inc);
  } else if (auto *SI = dyn_cast<SelectInst>(V)) {
    if (auto *C = dyn_cast<ConstantInt>(SI->getCondition())) {
      Value *Arm = C->isZero() ? SI->getFalseValue() : SI->getTrueValue();
      if (!SkipVacuous(Arm))
        Inputs.push_back(Arm);
    } else {
      if (!SkipVacuous(SI->getTrueValue()))
        Inputs.push_back(SI->getTrueValue());
      if (!SkipVacuous(SI->getFalseValue()))
        Inputs.push_back(SI->getFalseValue());
    }
  } else if (auto *FI = dyn_cast<FreezeInst>(V)) {
    Inputs.push_back(FI->getOperand(0));
  } else if (Value *Input = getJavaIdentityInput(V)) {
    Inputs.push_back(Input);
  } else {
    return false;
  }
  return true;
}

/// A leaf has a known definedness result. Other supported operations are
/// defined if all the collected inputs are defined. This is deliberately
/// context independent so the completion cache can be shared by CFG queries.
static std::optional<bool>
getDefinednessInputs(Value *V, SmallVectorImpl<Value *> &Inputs) {
  if (isa<PoisonValue, UndefValue>(V))
    return false;
  if (isa<FreezeInst, AllocaInst>(V))
    return true;
  if (auto *Arg = dyn_cast<Argument>(V))
    return Arg->hasAttribute(llvm::Attribute::NoUndef) ||
           Arg->hasAttribute(llvm::Attribute::Dereferenceable) ||
           Arg->hasAttribute(llvm::Attribute::DereferenceableOrNull);
  // A returned argument does not prove the result defined: parameter or return
  // attributes can introduce poison even when the actual argument is defined.
  if (auto *CB = dyn_cast<CallBase>(V)) {
    // The Jeandle check helpers return a concrete boolean for every contract-
    // valid input (their templates compute it from memory reads and
    // comparisons), so their results are defined without a noundef attribute.
    // This is the same name-based helper contract the tracing relies on.
    if (const Function *Callee = CB->getCalledFunction())
      if (Callee->getName() == "jeandle.check_instanceof" ||
          Callee->getName() == "jeandle.check_exact_klass" ||
          Callee->getName() == "jeandle.check_klass_subtype")
        return true;
    return CB->hasRetAttr(llvm::Attribute::NoUndef) ||
           CB->hasRetAttr(llvm::Attribute::Dereferenceable) ||
           CB->hasRetAttr(llvm::Attribute::DereferenceableOrNull);
  }
  if (auto *LI = dyn_cast<LoadInst>(V))
    return LI->hasMetadata(LLVMContext::MD_noundef) ||
           LI->hasMetadata(LLVMContext::MD_dereferenceable) ||
           LI->hasMetadata(LLVMContext::MD_dereferenceable_or_null);
  if (isa<ConstantInt, ConstantFP, ConstantPointerNull, GlobalValue,
          ConstantAggregateZero>(V))
    return true;
  if (auto *PN = dyn_cast<PHINode>(V)) {
    if (PN->getNumIncomingValues() == 0)
      return false;
    getBaseTypeInputs(V, Inputs, /*SkipVacuousArms=*/false);
    return std::nullopt;
  }
  if (auto *SI = dyn_cast<SelectInst>(V)) {
    getBaseTypeInputs(V, Inputs, /*SkipVacuousArms=*/false);
    Inputs.push_back(SI->getCondition());
    return std::nullopt;
  }
  if (auto *GEP = dyn_cast<GEPOperator>(V)) {
    if (!GEP->hasAllZeroIndices())
      return false;
    // All-zero indices cannot violate GEP's bounds or no-wrap promises.
    Inputs.push_back(GEP->getPointerOperand());
    return std::nullopt;
  }
  if (auto *Op = dyn_cast<Operator>(V)) {
    if (Op->hasPoisonGeneratingFlags())
      return false;
    switch (Op->getOpcode()) {
    case Instruction::ICmp:
    case Instruction::BitCast:
    case Instruction::PtrToInt:
    case Instruction::IntToPtr:
    case Instruction::Trunc:
    case Instruction::ZExt:
    case Instruction::SExt:
    case Instruction::Add:
    case Instruction::Sub:
    case Instruction::Mul:
    case Instruction::And:
    case Instruction::Or:
    case Instruction::Xor:
      Inputs.append(Op->op_begin(), Op->op_end());
      return std::nullopt;
    default:
      break;
    }
  }
  // In particular, an addrspacecast may produce poison even from a defined
  // pointer when the target does not support the conversion.
  return false;
}

/// Prove definedness without recursion. A supported cycle needs a path to a
/// defined leaf, and every dependency must be supported and defined. Reverse
/// edges first ground the cycles, then propagate unsupported/poison inputs.
/// Only completed results enter Memo, including intermediate cycle members.
static bool isProvenDefined(Value *V, DefinedMemo &Memo) {
  if (auto It = Memo.find(V); It != Memo.end())
    return It->second;

  DenseMap<Value *, SmallVector<Value *, 2>> Users;
  SmallPtrSet<Value *, 32> Visited;
  SmallVector<Value *, 16> Pending{V};
  SmallVector<Value *, 16> Defined;
  SmallVector<Value *, 16> Unknown;
  while (!Pending.empty()) {
    Value *Current = Pending.pop_back_val();
    if (!Visited.insert(Current).second)
      continue;
    SmallVector<Value *, 4> Inputs;
    std::optional<bool> Leaf;
    if (auto It = Memo.find(Current); It != Memo.end())
      Leaf = It->second;
    else
      Leaf = getDefinednessInputs(Current, Inputs);
    if (Leaf) {
      (*Leaf ? Defined : Unknown).push_back(Current);
      continue;
    }
    for (Value *Input : Inputs) {
      Users[Input].push_back(Current);
      Pending.push_back(Input);
    }
  }

  auto Propagate = [&](SmallVectorImpl<Value *> &Work,
                       SmallPtrSetImpl<Value *> &Reached) {
    while (!Work.empty()) {
      Value *Current = Work.pop_back_val();
      if (!Reached.insert(Current).second)
        continue;
      if (auto It = Users.find(Current); It != Users.end())
        Work.append(It->second.begin(), It->second.end());
    }
  };
  SmallPtrSet<Value *, 32> Grounded;
  Propagate(Defined, Grounded);
  for (Value *Current : Visited)
    if (!Grounded.contains(Current))
      Unknown.push_back(Current);
  SmallPtrSet<Value *, 32> NotDefined;
  Propagate(Unknown, NotDefined);
  for (Value *Current : Visited)
    Memo[Current] = !NotDefined.contains(Current);
  return Memo.lookup(V);
}

bool jeandle::isProvenDefined(Value *V) {
  DefinedMemo Memo;
  return ::isProvenDefined(V, Memo);
}

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

static JavaType getBaseJavaTypeLeaf(Value *V) {
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
      LLVM_DEBUG(dbgs() << "JavaType: malformed java-klass parameter attribute "
                        << KlassStr << " on " << *Arg << "\n");
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
      LLVM_DEBUG(dbgs() << "JavaType: malformed java-klass return attribute "
                        << KlassStr << " on " << *CB << "\n");
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
      LLVM_DEBUG(dbgs() << "JavaType: malformed !java-klass metadata on " << *LI
                        << "\n");
    }

    // Constant oop: the frontend emits a compile-time-known object reference
    // as an oop_handle_* global load WITHOUT !java-klass metadata. Recognize
    // the handle by name and query the oop's exact runtime klass via the VM.
    // Exact is sound because a constant oop is a single, fixed instance, so the
    // returned klass is the value's exact dynamic type (the actual subclass is
    // attributed directly, not a declared supertype).
    if (isJavaOopType(LI->getType())) {
      if (std::optional<int> Id = getOopHandleId(LI->getPointerOperand())) {
        const VMCallbacks *CB = getVMCallbacks();
        if (CB && CB->GetOopKlass) {
          if (uintptr_t Klass = CB->GetOopKlass(*Id); Klass != 0) {
            return {Klass, /*Exact=*/true};
          }
        }
      }
    }
    return {};
  }

  return {};
}

namespace {

struct BaseTypeNode {
  Value *V;
  SmallVector<Value *, 2> Inputs;
  size_t NextInput = 0;
  unsigned Index;
  bool OnStack = true;
  BaseTypeNode *PendingChild = nullptr;
  JavaType Seed;
  JavaType Result;
  bool First = true;
};

} // namespace

/// PHIs and selects union their inputs; identity expressions forward an input.
/// Evaluate inputs on demand with an iterative path-based SCC traversal.
/// Completed inputs are cached before siblings; a whole cycle is typed at
/// once by the join of the completed inputs entering it, and freeze only
/// forwards a type that comes with a definedness proof. Neither traversal
/// uses the C++ call stack.
static JavaType getBaseJavaType(Value *V, BaseMemo *Memo = nullptr,
                                DefinedMemo *Defined = nullptr) {
  BaseMemo LocalMemo;
  BaseMemo &Cache = Memo ? *Memo : LocalMemo;
  if (auto It = Cache.find(V); It != Cache.end())
    return It->second;
  SmallVector<Value *, 2> Inputs;
  if (!getBaseTypeInputs(V, Inputs, /*SkipVacuousArms=*/true)) {
    JavaType Result = getBaseJavaTypeLeaf(V);
    Cache[V] = Result;
    return Result;
  }

  DenseMap<Value *, std::unique_ptr<BaseTypeNode>> Nodes;
  DefinedMemo LocalDefined;
  DefinedMemo &DefinedCache = Defined ? *Defined : LocalDefined;
  SmallVector<BaseTypeNode *, 16> Frames;
  SmallVector<BaseTypeNode *, 16> OpenNodes;
  SmallVector<BaseTypeNode *, 16> Roots;
  unsigned NextIndex = 0;
  auto Discover = [&](Value *Input) {
    auto N = std::make_unique<BaseTypeNode>();
    N->V = Input;
    N->Index = NextIndex++;
    N->Seed = getBaseJavaTypeLeaf(Input);
    if (!getBaseTypeInputs(Input, N->Inputs, /*SkipVacuousArms=*/true))
      Cache[Input] = N->Seed;
    BaseTypeNode *Raw = N.get();
    Nodes[Input] = std::move(N);
    Frames.push_back(Raw);
    OpenNodes.push_back(Raw);
    Roots.push_back(Raw);
    return Raw;
  };
  auto JoinInput = [&](BaseTypeNode *N, Value *Input) {
    joinArm(N->Result, N->First, Cache.lookup(Input));
    // Unknown absorbs the remaining arms. Complete this node locally: an
    // ancestor may still have an independent return-attribute constraint.
    if (N->Result.isUnknown())
      N->NextInput = N->Inputs.size();
  };
  Discover(V);
  while (!Frames.empty()) {
    BaseTypeNode *N = Frames.back();
    if (auto It = Cache.find(N->V); It != Cache.end()) {
      // Leaves cannot belong to a cycle.
      assert(OpenNodes.back() == N && "leaf must be the last open node");
      assert(Roots.back() == N && "leaf must be its own component root");
      OpenNodes.pop_back();
      Roots.pop_back();
      N->OnStack = false;
      Frames.pop_back();
      continue;
    }
    if (BaseTypeNode *Child = N->PendingChild) {
      N->PendingChild = nullptr;
      if (!Child->OnStack)
        JoinInput(N, Child->V);
    }
    if (N->NextInput != N->Inputs.size()) {
      Value *Input = N->Inputs[N->NextInput++];
      if (Cache.contains(Input)) {
        JoinInput(N, Input);
      } else if (auto It = Nodes.find(Input); It != Nodes.end()) {
        BaseTypeNode *InputNode = It->second.get();
        assert(InputNode->OnStack && "completed input must be cached");
        // Merge the component roots joined by this edge, including a cross
        // edge to a completed DFS frame that is still in an open component.
        while (Roots.back()->Index > InputNode->Index)
          Roots.pop_back();
      } else {
        N->PendingChild = Discover(Input);
      }
      continue;
    }
    Frames.pop_back();
    if (Roots.back() != N)
      continue;
    Roots.pop_back();

    SmallVector<BaseTypeNode *, 4> Members;
    BaseTypeNode *Member;
    do {
      Member = OpenNodes.pop_back_val();
      Member->OnStack = false;
      Members.push_back(Member);
    } while (Member != N);
    bool HasCycle = Members.size() != 1 || llvm::is_contained(N->Inputs, N->V);
    if (!HasCycle) {
      JavaType Result = typeIntersect(std::move(N->Result), N->Seed);
      // freeze(x) is x only when x is defined; freezing a possibly-poison
      // reference yields an arbitrary one, so the operand's type cannot be
      // forwarded without a definedness proof.
      if (auto *FI = dyn_cast<FreezeInst>(N->V)) {
        if (!Result.isUnknown() &&
            !isProvenDefined(FI->getOperand(0), DefinedCache))
          Result = {};
      }
      Cache[N->V] = Result;
      continue;
    }
    // Every member of a cycle derives its values from the completed inputs
    // entering the cycle — PHI and select only choose among their operands —
    // so all defined observations of any member stay inside the join of
    // those inputs, and a member whose inputs all come from inside the cycle
    // is covered by the other members' inputs. A cycle with no completed
    // input at all joins nothing and stays unknown. A freeze can participate
    // only if its operand is defined, making it an identity expression.
    bool HasUnknownFreeze = llvm::any_of(Members, [&](BaseTypeNode *M) {
      auto *FI = dyn_cast<FreezeInst>(M->V);
      return FI && !isProvenDefined(FI->getOperand(0), DefinedCache);
    });
    JavaType Result;
    bool First = true;
    if (!HasUnknownFreeze)
      for (BaseTypeNode *M : Members)
        for (Value *Input : M->Inputs) {
          // Internal edges add no type; only completed external inputs join.
          if (auto It = Cache.find(Input); It != Cache.end())
            joinArm(Result, First, It->second);
        }
    // The external-input join bounds every member. Independent result seeds
    // can further constrain individual members and propagate around the SCC.
    // Each update retains its previous bound, so only stronger facts enter
    // the worklist; intermediate component states are not exposed to users.
    for (BaseTypeNode *M : Members)
      Cache[M->V] = typeIntersect(Result, M->Seed);
    DenseMap<Value *, SmallVector<BaseTypeNode *, 2>> Users;
    SmallVector<BaseTypeNode *, 16> Pending;
    SmallPtrSet<BaseTypeNode *, 32> Queued;
    for (BaseTypeNode *M : Members) {
      Pending.push_back(M);
      Queued.insert(M);
      for (Value *Input : M->Inputs)
        Users[Input].push_back(M);
    }
    while (!Pending.empty()) {
      BaseTypeNode *M = Pending.pop_back_val();
      Queued.erase(M);
      JavaType Derived;
      bool FirstInput = true;
      auto *FI = dyn_cast<FreezeInst>(M->V);
      if (!FI || isProvenDefined(FI->getOperand(0), DefinedCache))
        for (Value *Input : M->Inputs)
          joinArm(Derived, FirstInput, Cache.lookup(Input));
      Derived = typeIntersect(std::move(Derived), M->Seed);
      JavaType &Previous = Cache[M->V];
      JavaType Refined = typeIntersect(Previous, std::move(Derived));
      // Unrepresentable intersections still satisfy the established bound.
      if (!Refined.isKnown() && Previous.isKnown()) {
        Refined.Klass = Previous.Klass;
        Refined.Exact = Previous.Exact;
      }
      if (Refined != Previous) {
        Previous = std::move(Refined);
        for (BaseTypeNode *User : Users[M->V])
          if (Queued.insert(User).second)
            Pending.push_back(User);
      }
    }
  }
  return Cache.lookup(V);
}

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
  JavaTypeQueryContext(DominatorTree &DT, IsNullEdgeOracle NullOracle)
      : DT(DT), NullOracle(NullOracle) {}

  DominatorTree &DT;
  IsNullEdgeOracle NullOracle;
  /// PHI cycle-detection set for the value dimension (phiValueType): a
  /// re-encountered PHI contributes nothing. Base-type queries detect
  /// cycles with their own SCC state and do not use this set.
  SmallPtrSet<const PHINode *, 8> PhiVisited;
  /// Complete base-type memo shared across the whole query (see BaseMemo).
  BaseMemo BaseTypes;
  /// Completed value-dimension results. Nested PHIs can depend on the active
  /// PHI stack, so only evaluations outside that stack enter this cache.
  DenseMap<Value *, JavaType> ValueTypes;
  SmallPtrSet<Value *, 16> ValueVisited;
  unsigned ValueCycles = 0;
  /// Definedness proofs shared by base typing and CFG identity matching.
  DefinedMemo DefinedValues;
  /// Per-(value, block) evaluation state for the block dimension: absent =
  /// not yet evaluated, nullopt = currently on the evaluation stack (a cycle
  /// the back-edge rule cannot cut), engaged = the completed join. One
  /// container for both memoization and cycle detection keeps the two from
  /// drifting apart across exit paths.
  DenseMap<std::pair<Value *, BasicBlock *>, std::optional<JavaType>> Processed;
  unsigned FactsBudget = MaxFactsJoinBlocks;
  unsigned PhiBudget = MaxFactsJoinBlocks;
  unsigned ConditionDepth = 0;
};

} // namespace

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

/// Positive proof that V is null on edge From -> To, answered by the query's
/// null-edge oracle (the LazyValueInfo-backed implementation recognizes null
/// tests directly on the edge's branch as well as threaded/indirect forms),
/// with a structural fallback for threaded shapes the oracle misses: null
/// tests on casted pointers and with the null constant on either operand
/// side. When in doubt the answer is false — keeping an edge is always sound.
static bool isNullEdge(Value *V, BasicBlock *From, BasicBlock *To,
                       const JavaTypeQueryContext &Q) {
  if (!Q.DT.isReachableFromEntry(From))
    return false; // Lattice reasoning is undefined for unreachable blocks;
                  // keep the edge (the conservative answer).
  if (Q.NullOracle && Q.NullOracle(V, From, To))
    return true;
  // Null at the top of From (a dominating null-check edge) means null on
  // every edge out of From, including this one: V is an SSA value, so its
  // null-ness cannot change inside the block.
  return isNullCheckPath(From, V, Q.DT);
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
///
/// Value domain. The traced expression is an integer whose value must encode
/// the check outcome. The trace tracks the exact pair of values the expression
/// can take — FailedValue when every matched check failed, PassedValue when
/// the outcome side held — with the invariant:
///
///   domain(E) ⊆ {FailedValue, PassedValue}, and
///   E == PassedValue ⟹ True* constraints hold,
///   E == FailedValue ⟹ False* constraints hold.
///
/// The check base sets {0, 1}; zext/sext/trunc map the pair through the cast
/// (so `sext i1 %check to i8` widens the domain to {0, -1}, NOT {0, 1}); And/
/// Or/Xor are matched only on i1, where the type system itself pins the
/// domain to {0, 1}; PHI and select arms must all share one pair, and a
/// constant arm is classified against that pair (a constant equal to neither
/// pair value makes the expression's value independent of the checks, so the
/// trace bails). Consumers evaluate discriminating tests (icmp against a
/// constant, switch case values) at the pair, never at an assumed {0, 1}.
struct TraceResult {
  uintptr_t TrueKlass = 0;
  SmallDenseSet<uintptr_t, 2> TrueInterfaces;
  SmallDenseSet<uintptr_t, 2> TrueExclusions;
  uintptr_t FalseKlass = 0;
  SmallDenseSet<uintptr_t, 2> FalseInterfaces;
  SmallDenseSet<uintptr_t, 2> FalseExclusions;
  APInt FailedValue{1, 0};
  APInt PassedValue{1, 1};

  bool matched() const {
    return TrueKlass != 0 || !TrueInterfaces.empty() ||
           !TrueExclusions.empty() || FalseKlass != 0 ||
           !FalseInterfaces.empty() || !FalseExclusions.empty();
  }
};

/// Restore the canonical i1 pairing. Branch and switch consumers map value 1
/// to the True* side and value 0 to the False* side, so an i1 result whose
/// pair came out inverted (FailedValue==1) must swap its constraint sides
/// together with the pair values. Wide results keep their mapped pair: they
/// are only consumed through discriminating tests (icmp/switch), which
/// evaluate at the pair and are orientation-independent.
static void canonicalizeI1Pair(TraceResult &R) {
  if (R.FailedValue.getBitWidth() != 1 || R.FailedValue.isZero())
    return;
  std::swap(R.TrueKlass, R.FalseKlass);
  std::swap(R.TrueInterfaces, R.FalseInterfaces);
  std::swap(R.TrueExclusions, R.FalseExclusions);
  std::swap(R.FailedValue, R.PassedValue);
}

} // anonymous namespace

/// Canonicalize identity expressions for matching CFG facts. A freeze shares
/// its operand's identity only when that operand is proven defined.
static Value *stripCastsAndFreeze(Value *V, DefinedMemo &Defined) {
  SmallPtrSet<Value *, 8> Visited;
  while (Visited.insert(V).second) {
    if (auto *FI = dyn_cast<FreezeInst>(V)) {
      if (!isProvenDefined(FI->getOperand(0), Defined))
        break;
      V = FI->getOperand(0);
    } else if (Value *Input = getJavaIdentityInput(V)) {
      V = Input;
    } else
      break;
  }
  return V;
}

/// Match `jeandle.check_exact_klass(ExpectedKlass, ActualKlass)`, where
/// one argument is loaded directly from `QueryObj` by `jeandle.load_klass`.
/// The intrinsic arguments are treated symmetrically because IR rewrites may
/// place the loaded Klass in either position. Both sides are canonicalized
/// with the definedness-aware freeze/identity stripping so wrappers added by
/// later passes (freeze of the oop, returned-argument calls) still match.
static bool isLoadKlassOf(Value *ValueToCheck, Value *QueryObj,
                          DefinedMemo &Defined) {
  Value *Stripped = stripCastsAndFreeze(ValueToCheck, Defined);
  auto *Load = dyn_cast<CallBase>(Stripped);
  return Load && Load->getCalledFunction() &&
         Load->getCalledFunction()->getName() == "jeandle.load_klass" &&
         Load->arg_size() == 1 &&
         stripCastsAndFreeze(Load->getArgOperand(0), Defined) ==
             stripCastsAndFreeze(QueryObj, Defined);
}

static uintptr_t traceExactKlassGuard(Value *Cond, Value *QueryObj,
                                      DefinedMemo &Defined) {
  auto *CB = dyn_cast<CallBase>(stripCastsAndFreeze(Cond, Defined));
  Function *Callee = CB ? CB->getCalledFunction() : nullptr;
  if (!Callee || Callee->getName() != "jeandle.check_exact_klass" ||
      CB->arg_size() != 2)
    return 0;

  bool FirstIsActual = isLoadKlassOf(CB->getArgOperand(0), QueryObj, Defined);
  bool SecondIsActual = isLoadKlassOf(CB->getArgOperand(1), QueryObj, Defined);
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

/// Recursively trace a branch condition back to a jeandle.check_instanceof
/// call on QueryObj. Returns a matched TraceResult if successful, or an
/// unmatched TraceResult ({Klass=0}) if the condition cannot be linked to a
/// check_instanceof on QueryObj. See TraceResult for the value-domain
/// invariant maintained alongside the constraint fields.
static TraceResult traceToCheckInstanceof(Value *Cond, Value *QueryObj,
                                          SmallPtrSetImpl<Value *> &Visited,
                                          JavaTypeQueryContext &Q) {
  // Condition expressions can be deep even in a single basic block. Bound
  // their call-stack use independently of the CFG and PHI query budgets.
  static constexpr unsigned MaxConditionDepth = 32;
  if (Q.ConditionDepth == MaxConditionDepth)
    return {};
  ++Q.ConditionDepth;
  auto DepthGuard = make_scope_exit([&] { --Q.ConditionDepth; });

  // Canonicalize the queried object with the same definedness-aware strip the
  // per-arm matching below uses, so a frozen or identity-wrapped oop matches
  // its checks regardless of which side introduced the wrapper.
  QueryObj = stripCastsAndFreeze(QueryObj->stripPointerCastsAndAliases(),
                                 Q.DefinedValues);
  // Avoid infinite recursion on cyclic value graphs.
  if (!Visited.insert(Cond).second)
    return {}; // Already visited — no match on this path.

  // --- Freeze: transparent only with a definedness proof ---
  // freeze(x) equals x unless x is poison, in which case freeze materializes
  // an arbitrary value and the edge outcome says nothing about the checks.
  if (auto *FI = dyn_cast<FreezeInst>(Cond)) {
    if (!isProvenDefined(FI->getOperand(0), Q.DefinedValues))
      return {};
    return traceToCheckInstanceof(FI->getOperand(0), QueryObj, Visited, Q);
  }

  // --- Base case: direct call/invoke to jeandle.check_instanceof ---
  if (auto *CB = dyn_cast<CallBase>(Cond)) {
    uintptr_t Klass = 0;
    Value *Obj = nullptr;
    if (isCheckInstanceofCall(CB, Klass, Obj) &&
        stripCastsAndFreeze(Obj, Q.DefinedValues) == QueryObj) {
      TraceResult R;
      R.TrueKlass = Klass; // check passed → obj IS Klass
      R.TrueInterfaces = getFullInterfaces(Klass, {});
      R.FalseExclusions.insert(Klass); // check failed → obj IS NOT Klass
      R.FailedValue = APInt(1, 0);
      R.PassedValue = APInt(1, 1);
      return R;
    }
    return {}; // Not a check_instanceof on QueryObj.
  }

  // --- ICmp: comparisons that test the result of a type check ---
  //
  // The value being compared ultimately derives from a check_instanceof, but
  // it may have been widened or narrowed (zext, sext, trunc) and merged with
  // constants (phi, select). Rather than assuming a {0,1} domain, trace the
  // non-constant operand first: a successful trace reports the exact pair of
  // values the expression can take (see TraceResult). Evaluating the
  // predicate at that pair — instead of at an assumed {0,1} — is what keeps
  // widened forms honest:
  //
  //   `%s = sext i1 %check to i8; icmp sle i8 %s, 0`:
  //     The real domain is {0, -1}; sle(0,0) and sle(-1,0) are both true, so
  //     the comparison is constant — no match (an assumed {0,1} domain would
  //     wrongly read it as "true ⟺ check failed").
  //
  //   `icmp ne i32 %zext_val, 0` (domain {0, 1}):
  //     ne(0,0) → false, ne(1,0) → true — discriminating, true when the
  //     check passed → not negated.
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
      TraceResult R = traceToCheckInstanceof(Val, QueryObj, Visited, Q);
      if (!R.matched())
        return {}; // Val doesn't trace to a check — no match.
      // Evaluate `icmp Pred %val, C` at the traced value pair. The pair's
      // width matches the icmp operand type by construction.
      assert(R.FailedValue.getBitWidth() ==
                 C->getType()->getIntegerBitWidth() &&
             "traced value pair must match the compared type");
      bool ResultForFailed =
          ICmpInst::compare(R.FailedValue, C->getValue(), Pred);
      bool ResultForPassed =
          ICmpInst::compare(R.PassedValue, C->getValue(), Pred);
      if (ResultForFailed != ResultForPassed) {
        // The icmp result is i1 and is true exactly on one side's value, so
        // its own domain pair is {0, 1} regardless of the operand's width.
        APInt Failed(1, 0), Passed(1, 1);
        if (!ResultForPassed) {
          // The comparison returns true exactly on the failed value.
          // Swap True ↔ False constraints to match the swapped pairing.
          std::swap(R.TrueKlass, R.FalseKlass);
          std::swap(R.TrueInterfaces, R.FalseInterfaces);
          std::swap(R.TrueExclusions, R.FalseExclusions);
        }
        R.FailedValue = std::move(Failed);
        R.PassedValue = std::move(Passed);
        return R;
      }
      // ResultForFailed == ResultForPassed: the comparison is always true or
      // always false over the traced domain. It provides no type information.
    }
    return {}; // No constant operand, or not discriminating — no match.
  }

  // --- ZExt / SExt / Trunc: cast the traced value pair through to the
  // result's width (e.g., `zext i1 %check_instanceof_result to i32` maps
  // {0,1} to {0,1}; `sext i1 ... to i8` maps it to {0,-1}). Casts that
  // preserve neither the pair nor the checks' semantics (bitcast, fpcast,
  // ...) are not meaningful here.
  if (auto *Cast = dyn_cast<CastInst>(Cond)) {
    if (isa<ZExtInst>(Cast) || isa<SExtInst>(Cast) || isa<TruncInst>(Cast)) {
      TraceResult R =
          traceToCheckInstanceof(Cast->getOperand(0), QueryObj, Visited, Q);
      if (!R.matched())
        return {};
      unsigned Width = Cast->getType()->getIntegerBitWidth();
      if (isa<ZExtInst>(Cast)) {
        R.FailedValue = R.FailedValue.zext(Width);
        R.PassedValue = R.PassedValue.zext(Width);
      } else if (isa<SExtInst>(Cast)) {
        R.FailedValue = R.FailedValue.sext(Width);
        R.PassedValue = R.PassedValue.sext(Width);
      } else {
        R.FailedValue = R.FailedValue.trunc(Width);
        R.PassedValue = R.PassedValue.trunc(Width);
      }
      // zext/sext are injective and keep a distinct pair distinct, but trunc
      // can collapse it (i8 {0,2} -> i1 is {0,0}). The cast result is then
      // constant w.r.t. the check outcome, so no edge fact may survive — the
      // same invariant the constant bitwise-op mapping enforces below.
      if (R.FailedValue == R.PassedValue)
        return {};
      canonicalizeI1Pair(R);
      return R;
    }
    return {};
  }

  // --- Boolean operators: matched on i1 only, plus constant pair mappings ---
  //
  // On i1 the type system pins the value domain to {0,1}, so the boolean
  // semantics below are exact and compose with the value-pair invariant. On
  // wider integers an operand's contribution is only its bit 0 (zext/sext of
  // an i1 preserve bit 0), which is not enough to justify the full-value
  // merges used here — e.g. `or i8 %zext_check, (select i1 ..., 2)` can be 3
  // no matter which way the checks went — so wider And/Or/Xor of two traced
  // values are conservatively unmatched. The common widened forms are still
  // recovered: InstCombine canonicalizes `or (zext a), (zext b)` to
  // `zext (or i1 a, b)`, which traces fine, and a bitwise op with a CONSTANT
  // is a deterministic function of the single traced operand, so the value
  // pair maps through it exactly (`xor i8 %zext_check, 1` keeps inverting;
  // `sub i1 0, %check` is the NOT before that canonicalization).
  if (auto *BO = dyn_cast<BinaryOperator>(Cond)) {
    if (BO->getOpcode() == Instruction::And ||
        BO->getOpcode() == Instruction::Or ||
        BO->getOpcode() == Instruction::Xor ||
        BO->getOpcode() == Instruction::Sub) {
      auto *LHSC = dyn_cast<ConstantInt>(BO->getOperand(0));
      auto *RHSC = dyn_cast<ConstantInt>(BO->getOperand(1));
      if ((LHSC == nullptr) != (RHSC == nullptr)) {
        // Exactly one constant operand: map the traced operand's pair through
        // the constant. The result is a deterministic function of that
        // operand, so its value domain is exactly the mapped pair and the
        // constraint sides carry over unchanged. Sub is order-sensitive:
        // C-Other and Other-C map the pair differently.
        Value *Other = LHSC ? BO->getOperand(1) : BO->getOperand(0);
        const APInt &C = (LHSC ? LHSC : RHSC)->getValue();
        TraceResult R = traceToCheckInstanceof(Other, QueryObj, Visited, Q);
        if (!R.matched())
          return {};
        assert(R.FailedValue.getBitWidth() == C.getBitWidth() &&
               "traced value pair must match the operand type");
        switch (BO->getOpcode()) {
        case Instruction::And:
          R.FailedValue &= C;
          R.PassedValue &= C;
          break;
        case Instruction::Or:
          R.FailedValue |= C;
          R.PassedValue |= C;
          break;
        case Instruction::Xor:
          R.FailedValue ^= C;
          R.PassedValue ^= C;
          break;
        case Instruction::Sub:
          if (LHSC) {
            R.FailedValue = C - R.FailedValue;
            R.PassedValue = C - R.PassedValue;
          } else {
            R.FailedValue = R.FailedValue - C;
            R.PassedValue = R.PassedValue - C;
          }
          break;
        default:
          llvm_unreachable("covered above");
        }
        if (R.FailedValue == R.PassedValue)
          return {}; // Constant w.r.t. the check outcome — no discrimination.
        // xor (and an inverted sub) flips the value-outcome correspondence;
        // an i1 result must re-pair its constraint sides with it.
        canonicalizeI1Pair(R);
        return R;
      }
      if (!BO->getType()->isIntegerTy(1))
        return {};
    }
    // --- And i1 %a, %b ---
    // True-branch: both operands are true → AllOf (both constraints hold).
    // False-branch: at least one is false → OneOf (don't know which failed).
    if (BO->getOpcode() == Instruction::And) {
      TraceResult L =
          traceToCheckInstanceof(BO->getOperand(0), QueryObj, Visited, Q);
      TraceResult R =
          traceToCheckInstanceof(BO->getOperand(1), QueryObj, Visited, Q);
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
          traceToCheckInstanceof(BO->getOperand(0), QueryObj, Visited, Q);
      TraceResult R =
          traceToCheckInstanceof(BO->getOperand(1), QueryObj, Visited, Q);
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
            traceToCheckInstanceof(NonConstVal, QueryObj, Visited, Q);
        if (!R.matched())
          return {};
        // xor with true inverts the condition → swap True/False. The result
        // is i1, so its value pair stays {0,1}: value 1 now corresponds to
        // the operand's failed execution, which is the swapped-True side.
        std::swap(R.TrueKlass, R.FalseKlass);
        std::swap(R.TrueInterfaces, R.FalseInterfaces);
        std::swap(R.TrueExclusions, R.FalseExclusions);
        return R;
      }

      // --- Xor i1 %a, %b: true ⟺ exactly one operand is true ---
      // True side = OneOf(AllOf(a passed, b failed), AllOf(b passed, a
      // failed)); false side = OneOf(AllOf(both passed), AllOf(both failed))
      // — the operands agree. An AllOf arm whose merged facts contradict each
      // other describes a dead outcome; joining it anyway can only weaken the
      // result, never falsify it. With only one operand matched no constraint
      // is implied by the xor outcome (either operand may take either value),
      // so that case stays unmatched.
      TraceResult L = traceToCheckInstanceof(LHS, QueryObj, Visited, Q);
      TraceResult R = traceToCheckInstanceof(RHS, QueryObj, Visited, Q);
      if (L.matched() && R.matched()) {
        auto AllOfSide = [](const TraceResult &A, bool ATrue,
                            const TraceResult &B, bool BTrue) {
          TraceResult Out;
          Out.TrueKlass = pickMostSpecific(ATrue ? A.TrueKlass : A.FalseKlass,
                                           BTrue ? B.TrueKlass : B.FalseKlass);
          Out.TrueInterfaces = ATrue ? A.TrueInterfaces : A.FalseInterfaces;
          Out.TrueInterfaces = combinedInterfaces(
              Out.TrueInterfaces, BTrue ? B.TrueInterfaces : B.FalseInterfaces);
          Out.TrueExclusions = ATrue ? A.TrueExclusions : A.FalseExclusions;
          unionExcludedKlasses(Out.TrueExclusions,
                               BTrue ? B.TrueExclusions : B.FalseExclusions);
          return Out;
        };
        TraceResult PassedFailed = AllOfSide(L, true, R, false);
        TraceResult FailedPassed = AllOfSide(R, true, L, false);
        TraceResult PassedPassed = AllOfSide(L, true, R, true);
        TraceResult FailedFailed = AllOfSide(L, false, R, false);
        TraceResult M;
        M.TrueKlass =
            computeLCA(PassedFailed.TrueKlass, FailedPassed.TrueKlass);
        M.TrueInterfaces = commonInterfaces(PassedFailed.TrueInterfaces,
                                            FailedPassed.TrueInterfaces);
        M.TrueExclusions = intersectExcludedKlasses(
            PassedFailed.TrueExclusions, FailedPassed.TrueExclusions);
        M.FalseKlass =
            computeLCA(PassedPassed.TrueKlass, FailedFailed.TrueKlass);
        M.FalseInterfaces = commonInterfaces(PassedPassed.TrueInterfaces,
                                             FailedFailed.TrueInterfaces);
        M.FalseExclusions = intersectExcludedKlasses(
            PassedPassed.TrueExclusions, FailedFailed.TrueExclusions);
        return M;
      }
      return {};
    }

    return {}; // Other binary ops — not handled.
  }

  // --- Select: the result is one of two values, we don't know which ---
  // Both branches use OneOf semantics: LCA for klass, intersect for exclusions.
  // Constant arms are classified against the traced value pair, never against
  // an assumed {0,1}: a constant equal to one pair value behaves like that
  // side arriving without a check, and any other constant makes the result
  // independent of the checks (no match).
  if (auto *SI = dyn_cast<SelectInst>(Cond)) {
    Value *TrueVal = SI->getTrueValue();
    Value *FalseVal = SI->getFalseValue();
    auto *TrueConst = dyn_cast<ConstantInt>(TrueVal);
    auto *FalseConst = dyn_cast<ConstantInt>(FalseVal);

    // Both arms constant: the select maps the condition onto the constant
    // pair — the result equals TrueConst exactly when the condition is true.
    // Trace the condition and rebase the value pair onto the constants.
    if (TrueConst && FalseConst) {
      if (TrueConst->getValue() == FalseConst->getValue())
        return {}; // Constant result — independent of any check.
      TraceResult R =
          traceToCheckInstanceof(SI->getCondition(), QueryObj, Visited, Q);
      if (!R.matched())
        return {};
      R.FailedValue = FalseConst->getValue();
      R.PassedValue = TrueConst->getValue();
      canonicalizeI1Pair(R);
      return R;
    }

    // One arm is constant.
    if (TrueConst || FalseConst) {
      Value *NonConstVal = TrueConst ? FalseVal : TrueVal;
      TraceResult R = traceToCheckInstanceof(NonConstVal, QueryObj, Visited, Q);
      if (!R.matched())
        return {};
      // The constant arm contributes its value without any check. It must be
      // one of the pair values; which one decides which select outcome is
      // check-independent and must be dropped.
      const APInt &ConstVal =
          TrueConst ? TrueConst->getValue() : FalseConst->getValue();
      bool ConstIsFailed = ConstVal == R.FailedValue;
      bool ConstIsPassed = ConstVal == R.PassedValue;
      if (!ConstIsFailed && !ConstIsPassed)
        return {}; // Third value: the result is check-independent.
      TraceResult M;
      if (ConstIsFailed) {
        // Constant at the failed value: a result at the passed value can only
        // come from the non-constant arm — its passed side holds.
        M.TrueKlass = R.TrueKlass;
        M.TrueInterfaces = R.TrueInterfaces;
        M.TrueExclusions = R.TrueExclusions;
        // Failed outcome: could be the constant arm or R failing → no info.
      } else {
        // Constant at the passed value: a result at the failed value can only
        // come from the non-constant arm — its failed side holds.
        M.FalseKlass = R.FalseKlass;
        M.FalseInterfaces = R.FalseInterfaces;
        M.FalseExclusions = R.FalseExclusions;
        // Passed outcome: could be the constant arm or R passing → no info.
      }
      if (!M.matched())
        return {};
      M.FailedValue = R.FailedValue;
      M.PassedValue = R.PassedValue;
      return M;
    }

    // Both non-constant: OneOf merge. The arms must share one value pair for
    // the merged result to have a well-defined domain.
    TraceResult T = traceToCheckInstanceof(TrueVal, QueryObj, Visited, Q);
    if (!T.matched())
      return {}; // True arm doesn't trace — no match.
    TraceResult F = traceToCheckInstanceof(FalseVal, QueryObj, Visited, Q);
    if (!F.matched())
      return {}; // False arm doesn't trace — no match.
    if (T.FailedValue != F.FailedValue || T.PassedValue != F.PassedValue)
      return {}; // Different pairs — no common value semantics.
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
    M.FailedValue = T.FailedValue;
    M.PassedValue = T.PassedValue;
    return M;
  }

  // --- PHI: merge non-constant incomings with OneOf semantics ---
  // Don't know which incoming was selected → LCA for klass, intersect for
  // exclusions, on both branches. Constant incomings are classified against
  // the traced value pair after the non-constant arms establish it: a
  // constant equal to a pair value makes that outcome check-independent, and
  // any other constant makes the whole phi's value check-independent (the
  // phi could hold a value the checks can never produce, on either outcome).
  if (auto *PN = dyn_cast<PHINode>(Cond)) {
    TraceResult M;
    bool HaveMatch = false;
    SmallVector<ConstantInt *, 2> ConstantArms;

    for (unsigned I = 0, E = PN->getNumIncomingValues(); I != E; ++I) {
      Value *Inc = PN->getIncomingValue(I);

      // If the incoming block is dominated by a null-check edge (obj IS null
      // there), the arm is only live for the null execution, where type
      // facts conditioned on non-null are meaningless — skip it regardless
      // of whether the incoming is a constant. This stays on the structural
      // dominator walk only: the null-edge oracle (LazyValueInfo) may only
      // be queried with values that dominate the edge, which is not
      // guaranteed between a traced condition's PHI arms and QueryObj.
      BasicBlock *IncBB = PN->getIncomingBlock(I);
      if (isNullCheckPath(IncBB, QueryObj, Q.DT))
        continue;

      if (auto *CI = dyn_cast<ConstantInt>(Inc)) {
        ConstantArms.push_back(CI);
        continue;
      }

      // Non-constant incoming: must trace to a check_instanceof.
      TraceResult R = traceToCheckInstanceof(Inc, QueryObj, Visited, Q);
      if (!R.matched())
        return {}; // This incoming doesn't trace to a check — no match.
      if (!HaveMatch) {
        M = R;
        HaveMatch = true;
      } else if (M.FailedValue != R.FailedValue ||
                 M.PassedValue != R.PassedValue) {
        return {}; // Arms with different value pairs — no common semantics.
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
    if (!HaveMatch)
      return {}; // No non-constant incomings (all were skipped) — no match.

    // Classify the constant arms against the merged value pair and drop the
    // outcomes they can reach without a check.
    bool HasConstantFailed = false;
    bool HasConstantPassed = false;
    for (ConstantInt *CI : ConstantArms) {
      if (CI->getValue() == M.FailedValue)
        HasConstantFailed = true;
      else if (CI->getValue() == M.PassedValue)
        HasConstantPassed = true;
      else
        return {}; // A value outside the pair — check-independent phi.
    }
    if (HasConstantFailed) {
      M.FalseKlass = 0;
      M.FalseInterfaces.clear();
      M.FalseExclusions.clear();
    }
    if (HasConstantPassed) {
      M.TrueKlass = 0;
      M.TrueInterfaces.clear();
      M.TrueExclusions.clear();
    }
    if (M.matched())
      return M;
    return {};
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
// The seed cut at V's definition block is exact in reducible CFGs: a branch
// condition referencing V is dominated by V's definition, so an edge into the
// definition block carrying facts about V would come from a dominated
// predecessor — a back edge, which is skipped anyway. In an irreducible CFG a
// reference can also reach the definition block without such a dominator
// chain (an indirect reference through a PHI of V); the cut still returns
// only unknown, which is sound — the cost is precision, and only for
// irreducible loops.
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
  assert(getVMCallbacks() && getVMCallbacks()->IsSubtype &&
         "VMCallbacks must be set");
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
      // G is the narrower constraint and replaces the accumulated klass.
      // Exactness stays disjunctive, mirroring typeIntersect's ladder: a
      // exact claim on either side pins the dynamic type (an accumulated
      // exact klass with a narrower instanceof guard only coexist on dead
      // paths, where keeping exact is vacuously sound).
      Acc.Klass = G.Klass;
      Acc.Exact = Acc.Exact || G.Exact;
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

/// The guard that edge From -> To implies about V. For a conditional branch,
/// if exactly one successor is To, that outcome's constraints held along the
/// edge; a duplicate edge (both successors are To) carries no outcome
/// information. For a switch, an edge reached through exactly one case value
/// (or through the default when exactly one pair value is cased elsewhere)
/// pins the condition to that value. Other terminators carry no guard.
static JavaType edgeGuard(BasicBlock *From, BasicBlock *To, Value *V,
                          JavaTypeQueryContext &Q) {
  // Same canonicalization as the trace entry, so a guard on a frozen or
  // identity-wrapped oop constrains the underlying object's type query.
  V = stripCastsAndFreeze(V->stripPointerCastsAndAliases(), Q.DefinedValues);
  auto *BI = dyn_cast<BranchInst>(From->getTerminator());
  auto *SW = dyn_cast<SwitchInst>(From->getTerminator());
  Value *Cond = nullptr;
  if (SW)
    Cond = SW->getCondition();
  else if (BI && BI->isConditional())
    Cond = BI->getCondition();
  if (!Cond)
    return {}; // Unconditional branch, switch-free terminator, or no outcome.
  // The condition side gets the same definedness-aware canonicalization as
  // the object side, so a frozen or identity-wrapped condition still traces.
  Cond = stripCastsAndFreeze(Cond, Q.DefinedValues);

  if (BI) {
    BasicBlock *TrueBB = BI->getSuccessor(0);
    BasicBlock *FalseBB = BI->getSuccessor(1);
    bool TrueIsTo = (TrueBB == To);
    bool FalseIsTo = (FalseBB == To);
    if (TrueIsTo == FalseIsTo)
      return {};

    // Exact-klass guard fast path. A failed exact-class guard does not imply
    // that the object is not an instance of the guarded class: it may still be
    // a subclass, so the false side contributes nothing.
    if (uintptr_t Exact = traceExactKlassGuard(Cond, V, Q.DefinedValues)) {
      if (TrueIsTo) {
        LLVM_DEBUG(dbgs() << "JavaType: edge guard " << From->getName()
                          << " -> " << To->getName() << " proves exact klass "
                          << Exact << " for " << *V << "\n");
        return JavaType(Exact, /*Exact=*/true);
      }
      return {};
    }

    SmallPtrSet<Value *, 16> TraceVisited;
    TraceResult TR = traceToCheckInstanceof(Cond, V, TraceVisited, Q);
    if (!TR.matched())
      return {};

    LLVM_DEBUG(dbgs() << "JavaType: edge guard " << From->getName() << " -> "
                      << To->getName() << " constrains " << *V << "\n");
    if (TrueIsTo)
      return traceSideToFacts(TR.TrueKlass, TR.TrueInterfaces,
                              TR.TrueExclusions);
    return traceSideToFacts(TR.FalseKlass, TR.FalseInterfaces,
                            TR.FalseExclusions);
  }

  // --- Switch: an edge's case values pin the condition's value ---
  {
    SmallVector<ConstantInt *, 2> CasesToDest;
    bool DefaultIsDest = SW->getDefaultDest() == To;
    for (auto &Case : SW->cases())
      if (Case.getCaseSuccessor() == To)
        CasesToDest.push_back(Case.getCaseValue());

    // The value the condition is pinned to on this edge, if any.
    std::optional<APInt> PinnedValue;
    if (!DefaultIsDest && CasesToDest.size() == 1) {
      PinnedValue = CasesToDest.front()->getValue();
    } else if (DefaultIsDest && CasesToDest.empty()) {
      // Default edge: the value is anything not cased elsewhere. If exactly
      // one of the traced pair values is cased (to some other block), the
      // default edge pins the other one; if both or neither are cased, the
      // edge carries no check-outcome information.
      // Computed below against the traced pair.
      PinnedValue = std::nullopt;
    } else {
      return {}; // Mixed or multi-case destination — no single value.
    }

    SmallPtrSet<Value *, 16> TraceVisited;
    TraceResult TR = traceToCheckInstanceof(Cond, V, TraceVisited, Q);
    if (!TR.matched())
      return {};

    if (!PinnedValue) {
      bool FailedCased = false, PassedCased = false;
      for (auto &Case : SW->cases()) {
        if (Case.getCaseSuccessor() == To)
          continue;
        if (Case.getCaseValue()->getValue() == TR.FailedValue)
          FailedCased = true;
        if (Case.getCaseValue()->getValue() == TR.PassedValue)
          PassedCased = true;
      }
      if (FailedCased == PassedCased)
        return {}; // Both or neither cased — no discrimination.
      PinnedValue = FailedCased ? TR.PassedValue : TR.FailedValue;
    }

    LLVM_DEBUG(dbgs() << "JavaType: switch edge " << From->getName() << " -> "
                      << To->getName() << " pins the condition for " << *V
                      << "\n");
    if (*PinnedValue == TR.PassedValue)
      return traceSideToFacts(TR.TrueKlass, TR.TrueInterfaces,
                              TR.TrueExclusions);
    if (*PinnedValue == TR.FailedValue)
      return traceSideToFacts(TR.FalseKlass, TR.FalseInterfaces,
                              TR.FalseExclusions);
    return {}; // A case value outside the traced pair — a dead edge.
  }

  return {};
}

/// Facts holding about V at the top of BB: the join over non-skipped incoming
/// edges of (facts at the predecessor, narrowed by the edge guard).
/// Facts-only: check-derived constraints, never attribute/metadata base types.
static JavaType factsAt(Value *V, BasicBlock *BB, JavaTypeQueryContext &Q) {
  V = stripCastsAndFreeze(V, Q.DefinedValues);

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
    mergePathFacts(E, edgeGuard(P, BB, V, Q));
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

    // Literal null and poison incomings are vacuous under the non-null
    // contract (see getBaseTypeInputs) — same rule as the base engine, so a
    // lazy-initialization phi keeps its typed arm even without an oracle.
    if (isa<ConstantPointerNull, PoisonValue>(Inc))
      continue;

    JavaType T = valueDimension(Inc, Q);
    JavaType EdgeFacts = factsAt(Inc, IncBB, Q);
    JavaType GuardFacts = edgeGuard(IncBB, PN->getParent(), Inc, Q);
    // Dead incoming arm: the incoming's base type contradicts a failed check
    // on this edge, so the incoming has no non-null execution here (its only
    // live value is null). Under the non-null contract the arm is vacuous,
    // exactly like a proven-null edge, and is skipped instead of polluting
    // the join through the contradiction.
    if (T.isKnown() && (isExcludedBy(T.Klass, EdgeFacts.ExcludedKlasses) ||
                        isExcludedBy(T.Klass, GuardFacts.ExcludedKlasses)))
      continue;
    T = typeIntersect(T, EdgeFacts);
    mergePathFacts(T, GuardFacts);
    if (T.isUnknown())
      return {};
    joinArm(Result, First, std::move(T));
    if (Result.isUnknown())
      return {};
  }
  return Result;
}

/// The value dimension combines independent base constraints with incoming
/// edge facts for PHIs and definition-point operand facts for forwarders.
/// Cycles and exhausted budgets fall back to the complete base bound.
static JavaType valueDimension(Value *V, JavaTypeQueryContext &Q) {
  JavaType Base = getBaseJavaType(V, &Q.BaseTypes, &Q.DefinedValues);
  SmallVector<Value *, 4> Inputs;
  if (!getBaseTypeInputs(V, Inputs, /*SkipVacuousArms=*/true) || Base.Exact)
    return Base;
  if (auto It = Q.ValueTypes.find(V); It != Q.ValueTypes.end())
    return It->second;
  if (Q.ValueVisited.contains(V)) {
    ++Q.ValueCycles;
    return Base;
  }
  if (Q.PhiBudget == 0) {
    ++NumJavaTypeBudgetExhausted;
    return Base;
  }
  --Q.PhiBudget;
  bool CanMemoize = Q.PhiVisited.empty();
  unsigned Cycles = Q.ValueCycles;
  Q.ValueVisited.insert(V);
  auto StackGuard = make_scope_exit([&] { Q.ValueVisited.erase(V); });
  JavaType Derived;
  if (auto *PN = dyn_cast<PHINode>(V)) {
    Derived = phiValueType(PN, Q);
  } else {
    if (auto *FI = dyn_cast<FreezeInst>(V))
      if (!isProvenDefined(FI->getOperand(0), Q.DefinedValues))
        return Base;
    bool First = true;
    for (Value *Input : Inputs) {
      JavaType T = valueDimension(Input, Q);
      if (auto *I = dyn_cast<Instruction>(V))
        T = typeIntersect(T, factsAt(Input, I->getParent(), Q));
      joinArm(Derived, First, std::move(T));
    }
  }
  JavaType Result = typeIntersect(std::move(Base), std::move(Derived));
  if (CanMemoize && Cycles == Q.ValueCycles)
    Q.ValueTypes[V] = Result;
  return Result;
}

JavaType jeandle::sharpen(Value *V, Instruction *Context, DominatorTree &DT,
                          BasicBlock *DestBB, IsNullEdgeOracle IsNullEdge) {
  assert(getVMCallbacks() && getVMCallbacks()->IsSubtype &&
         "VMCallbacks must be set");
  // Contract (see JavaType.h): Context is the terminator of a PHI incoming
  // block and DestBB that PHI's parent. DestBB may equal Context's block for
  // a self-referencing PHI arm (a loop-header back edge); the guard on such
  // an edge is then conservatively empty (duplicate-edge rule in edgeGuard).
  assert(Context && Context->isTerminator() &&
         "sharpen requires the incoming block's terminator");
  assert(DestBB && "sharpen requires the PHI parent block");

  JavaTypeQueryContext Q{DT, IsNullEdge};
  V = stripCastsAndFreeze(V, Q.DefinedValues);
  JavaType Facts = factsAt(V, Context->getParent(), Q);
  mergePathFacts(Facts, edgeGuard(Context->getParent(), DestBB, V, Q));
  normalizeExcludedKlasses(Facts);
  return Facts;
}

// =============================================================================
// Main query
// =============================================================================

JavaType jeandle::getJavaType(Value *V, DominatorTree *DT, Instruction *Context,
                              IsNullEdgeOracle IsNullEdge) {
  assert(getVMCallbacks() && getVMCallbacks()->IsSubtype &&
         "VMCallbacks must be set");
  if (!DT || !Context) {
    DefinedMemo Defined;
    return getBaseJavaType(V, nullptr, &Defined);
  }

  JavaTypeQueryContext Q{*DT, IsNullEdge};
  JavaType T = valueDimension(V, Q);
  return typeIntersect(T, factsAt(V, Context->getParent(), Q));
}
