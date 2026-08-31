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
// This pass eliminates redundant jeandle.check_instanceof calls by using
// compile-time Java type information. It replaces calls with constant true
// (when the object's type is provably a subtype) or constant false (when the
// object's exact type is provably not a subtype).
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/TypeCheckElimination.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/JavaType.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Debug.h"

#define DEBUG_TYPE "type-check-elimination"

using namespace llvm;

PreservedAnalyses TypeCheckElimination::run(Function &F,
                                            FunctionAnalysisManager &FAM) {
  Module *M = F.getParent();
  if (!M->getNamedMetadata(jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();

  const jeandle::VMCallbacks *CB = jeandle::getVMCallbacks();
  assert(CB && CB->IsSubtype && CB->IsInterface && CB->IsObjectKlass &&
         "VMCallbacks must be set");

  Function *CheckFn = M->getFunction("jeandle.check_instanceof");
  if (!CheckFn)
    return PreservedAnalyses::all();

  DominatorTree &DT = FAM.getResult<DominatorTreeAnalysis>(F);

  // Collect all check_instanceof calls/invokes.
  SmallVector<CallBase *, 16> Checks;
  for (auto &I : instructions(F)) {
    auto *CheckCB = dyn_cast<CallBase>(&I);
    if (CheckCB && CheckCB->getCalledFunction() == CheckFn)
      Checks.push_back(CheckCB);
  }

  bool Changed = false;
  for (CallBase *CheckCB : Checks) {
    uintptr_t SuperKlass =
        jeandle::extractKlassConstant(CheckCB->getArgOperand(0));
    if (SuperKlass == 0)
      continue;

    // --- Fold to true: instanceof java.lang.Object ---
    // Every non-null object is an instance of Object, and the
    // check_instanceof helper's IR contract guarantees non-null.
    if (CB->IsObjectKlass(SuperKlass)) {
      LLVM_DEBUG(dbgs() << "TCE: instanceof Object, replacing with true: "
                        << *CheckCB << "\n");
      CheckCB->replaceAllUsesWith(ConstantInt::getTrue(CheckCB->getType()));
      CheckCB->eraseFromParent();
      Changed = true;
      continue;
    }

    Value *Obj = CheckCB->getArgOperand(1);
    // TCE queries JavaType only at jeandle.check_instanceof call sites. The
    // helper's IR contract requires this oop operand to be non-null, so
    // check_instanceof-derived sharpening remains sound even though JavaType
    // itself does not model nullability.
    jeandle::JavaType ObjType = jeandle::getJavaType(Obj, &DT, CheckCB);

    // --- Fold to true: known subtype ---
    if (ObjType.isKnown() && (CB->IsSubtype(ObjType.Klass, SuperKlass) ||
                              ObjType.Interfaces.contains(SuperKlass))) {
      LLVM_DEBUG(dbgs() << "TCE: known subtype, replacing with true: "
                        << *CheckCB << "\n");
      CheckCB->replaceAllUsesWith(ConstantInt::getTrue(CheckCB->getType()));
      CheckCB->eraseFromParent();
      Changed = true;
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

    if (FoldToFalse) {
      LLVM_DEBUG(dbgs() << "TCE: replacing with false: " << *CheckCB << "\n");
      CheckCB->replaceAllUsesWith(ConstantInt::getFalse(CheckCB->getType()));
      CheckCB->eraseFromParent();
      Changed = true;
    }
  }

  if (!Changed)
    return PreservedAnalyses::all();

  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>();
  PA.preserve<DominatorTreeAnalysis>();
  return PA;
}
