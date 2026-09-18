//===- TypeCheckElimination.cpp - Eliminate redundant type checks ---------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This pass eliminates redundant Java type checks by using compile-time Java
// type information. It folds jeandle.check_instanceof and
// jeandle.check_klass_subtype calls, and also folds
// jeandle.array_store_check to true when an exact destination-array type makes
// the store provably compatible. Array-store checks are never folded to false
// without a separate non-null proof for the stored value, because JavaType does
// not model nullability and null is assignable to every reference array.
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/TypeCheckElimination.h"
#include "llvm/Analysis/LazyValueInfo.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/JavaType.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Debug.h"
#include "llvm/Transforms/Jeandle/JeandleTransformUtils.h"

#define DEBUG_TYPE "type-check-elimination"

using namespace llvm;

namespace {

/// Replace a type-check call with a constant result and erase it. The check
/// helpers are only ever emitted as calls (never invokes): an invoke is a
/// terminator, and erasing one would destroy the CFG — so this only accepts
/// CallInst. An invoke-form check simply stays unfolded.
[[nodiscard]] bool foldCheckToConstant(CallInst *Check, Constant *Result) {
  assert(!isa<InvokeInst>(Check) &&
         "check helpers are never emitted as invokes");
  LLVM_DEBUG(dbgs() << "TCE: replacing with constant " << *Result << ": "
                    << *Check << "\n");
  Check->replaceAllUsesWith(Result);
  Check->eraseFromParent();
  return true;
}

} // namespace

PreservedAnalyses TypeCheckElimination::run(Function &F,
                                            FunctionAnalysisManager &FAM) {
  Module *M = F.getParent();
  if (!M->getNamedMetadata(jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();

  const jeandle::VMCallbacks *CB = jeandle::getVMCallbacks();
  assert(CB && CB->IsSubtype && CB->IsInterface && CB->IsObjectKlass &&
         CB->ArrayElementKlass &&
         "VMCallbacks must be set");
  if (!CB)
    return PreservedAnalyses::all();

  Function *CheckFn = M->getFunction("jeandle.check_instanceof");
  Function *SubtypeFn = M->getFunction("jeandle.check_klass_subtype");
  Function *ArrayStoreCheckFn = M->getFunction("jeandle.array_store_check");
  if (!CheckFn && !SubtypeFn && !ArrayStoreCheckFn)
    return PreservedAnalyses::all();

  DominatorTree &DT = FAM.getResult<DominatorTreeAnalysis>(F);
  // The LVI snapshot stays safe for the whole pass because TCE only erases
  // non-terminator CallInsts and never splits blocks: LVI's ValueHandles purge
  // erased/RAUW'd values from its caches, and block-value state stays valid
  // while the CFG is unchanged. A fold that touches terminators or blocks
  // would need to drop the oracle first.
  LazyValueInfo &LVI = FAM.getResult<LazyValueAnalysis>(F);
  LVINullEdgeOracle IsNullEdge{LVI};

  // Collect type-check calls. CallInst only: the check helpers are never
  // emitted as invokes, and an invoke must not be erased like a call (it is a
  // terminator) — an invoke-form check simply stays unfolded.
  SmallVector<CallInst *, 16> Checks;
  SmallVector<CallInst *, 16> SubtypeChecks;
  SmallVector<CallInst *, 16> ArrayStoreChecks;
  for (auto &I : instructions(F)) {
    auto *Check = dyn_cast<CallInst>(&I);
    if (!Check)
      continue;
    if (CheckFn && Check->getCalledFunction() == CheckFn)
      Checks.push_back(Check);
    if (SubtypeFn && Check->getCalledFunction() == SubtypeFn)
      SubtypeChecks.push_back(Check);
    if (ArrayStoreCheckFn && Check->getCalledFunction() == ArrayStoreCheckFn)
      ArrayStoreChecks.push_back(Check);
  }

  // All fold decisions are made against the original IR first and applied
  // afterwards: folding replaces a guard's branch condition with a constant,
  // which would hide the guard from a later check's condition tracing.
  // Deciding every fold up front keeps the result independent of iteration
  // order.
  struct FoldDecision {
    CallInst *Check;
    Constant *Result;
  };
  SmallVector<FoldDecision, 16> Folds;

  // --- Decide: fold constant check_klass_subtype ---
  // Both operands constant: a klass constant is an exact type descriptor, and
  // the runtime template computes exactly IsSubtype over the primary/secondary
  // supers, so the check is a pure function of the two constants. (Interfaces
  // included: there is no value-level imprecision for klass-on-klass.)
  for (CallInst *SubCB : SubtypeChecks) {
    uintptr_t Sub = jeandle::extractKlassConstant(SubCB->getArgOperand(0));
    uintptr_t Super = jeandle::extractKlassConstant(SubCB->getArgOperand(1));
    if (Sub == 0 || Super == 0)
      continue;
    bool Result = CB->IsSubtype(Sub, Super);
    Folds.push_back(
        {SubCB, ConstantInt::get(SubCB->getType(), Result ? 1 : 0)});
  }
  for (CallInst *CheckCB : Checks) {
    uintptr_t SuperKlass =
        jeandle::extractKlassConstant(CheckCB->getArgOperand(0));
    if (SuperKlass == 0)
      continue;

    // --- Fold to true: instanceof java.lang.Object ---
    // Every non-null object is an instance of Object, and the
    // check_instanceof helper's IR contract guarantees non-null.
    if (CB->IsObjectKlass(SuperKlass)) {
      Folds.push_back({CheckCB, ConstantInt::getTrue(CheckCB->getType())});
      continue;
    }

    Value *Obj = CheckCB->getArgOperand(1);
    // TCE queries JavaType only at jeandle.check_instanceof call sites. The
    // helper's IR contract requires this oop operand to be non-null, so
    // check_instanceof-derived sharpening remains sound even though JavaType
    // itself does not model nullability.
    jeandle::JavaType ObjType =
        jeandle::getJavaType(Obj, &DT, CheckCB, IsNullEdge);

    // --- Fold to true: known subtype ---
    if (ObjType.isKnown() && (CB->IsSubtype(ObjType.Klass, SuperKlass) ||
                              ObjType.Interfaces.contains(SuperKlass))) {
      Folds.push_back({CheckCB, ConstantInt::getTrue(CheckCB->getType())});
      continue;
    }

    // --- Fold to false ---
    bool FoldToFalse = false;

    if (ObjType.isKnown() && jeandle::areKlassesIncompatible(
                                 ObjType.Klass, ObjType.Exact, SuperKlass)) {
      LLVM_DEBUG(dbgs() << "TCE: incompatible class types\n");
      FoldToFalse = true;
    }

    // Check negative constraints: if SuperKlass is a subtype of any excluded
    // klass, the object can't be SuperKlass (excluding X implies excluding
    // all subtypes of X).
    if (!FoldToFalse && ObjType.hasExclusions()) {
      for (uintptr_t Excluded : ObjType.ExcludedKlasses) {
        if (CB->IsSubtype(SuperKlass, Excluded)) {
          LLVM_DEBUG(dbgs()
                     << "TCE: denied by excluded klass " << Excluded << "\n");
          FoldToFalse = true;
          break;
        }
      }
    }

    if (FoldToFalse)
      Folds.push_back({CheckCB, ConstantInt::getFalse(CheckCB->getType())});
  }

  // --- Decide: fold provably-compatible array stores ---
  //
  // Java arrays are covariant: a value whose declared type is Object[] may
  // refer to a String[] at runtime. Therefore the destination's JavaType must
  // be exact before its element klass can be used to remove a store check.
  // The frontend marks newarray/anewarray results with java-klass-exact, and
  // getJavaType also preserves exactness through supported PHI/select shapes.
  for (CallInst *StoreCB : ArrayStoreChecks) {
    if (StoreCB->arg_size() < 2)
      continue;

    Value *StoredValue = StoreCB->getArgOperand(0);
    Value *Array = StoreCB->getArgOperand(1);

    // null is assignable to every reference array. This proof is independent
    // of the destination's exact klass.
    if (isa<ConstantPointerNull>(StoredValue)) {
      Folds.push_back(
          {StoreCB, ConstantInt::getTrue(StoreCB->getType())});
      continue;
    }

    jeandle::JavaType ArrayType =
        jeandle::getJavaType(Array, &DT, StoreCB, IsNullEdge);
    if (!ArrayType.isKnown() || !ArrayType.Exact)
      continue;

    // ArrayElementKlass returns zero for primitive arrays, non-arrays, and
    // unavailable element metadata. aastore should only produce reference
    // arrays, but retain the check conservatively for malformed or unknown IR.
    uintptr_t ElementKlass = CB->ArrayElementKlass(ArrayType.Klass);
    if (ElementKlass == 0)
      continue;

    // An exact Object[] accepts every reference value, so no information
    // about StoredValue is required.
    if (CB->IsObjectKlass(ElementKlass)) {
      Folds.push_back(
          {StoreCB, ConstantInt::getTrue(StoreCB->getType())});
      continue;
    }

    jeandle::JavaType ValueType =
        jeandle::getJavaType(StoredValue, &DT, StoreCB, IsNullEdge);
    if (ValueType.isKnown() &&
        (CB->IsSubtype(ValueType.Klass, ElementKlass) ||
         ValueType.Interfaces.contains(ElementKlass))) {
      Folds.push_back(
          {StoreCB, ConstantInt::getTrue(StoreCB->getType())});
    }

    // Deliberately do not fold an incompatible value to false. JavaType does
    // not model nullability, so an apparently incompatible value may still be
    // null at runtime, in which case the array store check must succeed.
  }

  // --- Apply all folds ---
  bool Changed = false;
  for (const FoldDecision &F : Folds)
    Changed |= foldCheckToConstant(F.Check, F.Result);

  if (!Changed)
    return PreservedAnalyses::all();

  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>();
  PA.preserve<DominatorTreeAnalysis>();
  return PA;
}
