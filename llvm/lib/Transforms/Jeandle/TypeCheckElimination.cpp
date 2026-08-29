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
// This pass eliminates redundant Java type-check calls by using
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
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Jeandle/JavaType.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Debug.h"

#define DEBUG_TYPE "type-check-elimination"

using namespace llvm;

namespace {

void replaceCheckcastWithNullTest(CallBase *CheckCB, Value *Obj) {
  IRBuilder<> Builder(CheckCB);
  Value *IsNull = Builder.CreateICmpEQ(
      Obj, ConstantPointerNull::get(cast<PointerType>(Obj->getType())),
      "checkcast.null_result");
  CheckCB->replaceAllUsesWith(IsNull);
  CheckCB->eraseFromParent();
}

} // namespace

PreservedAnalyses TypeCheckElimination::run(Function &F,
                                            FunctionAnalysisManager &FAM) {
  Module *M = F.getParent();
  if (!M->getNamedMetadata(jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();

  const jeandle::VMCallbacks *CB = jeandle::getVMCallbacks();
  assert(CB && CB->IsSubtype && CB->IsInterface && CB->IsObjectKlass &&
         "VMCallbacks must be set");

  Function *InstanceofFn = M->getFunction("jeandle.check_instanceof");
  Function *KlassSubtypeFn = M->getFunction("jeandle.check_klass_subtype");
  Function *CheckCastFn = M->getFunction("jeandle.checkcast");
  if (!InstanceofFn && !KlassSubtypeFn && !CheckCastFn)
    return PreservedAnalyses::all();

  DominatorTree &DT = FAM.getResult<DominatorTreeAnalysis>(F);

  // checkcast stays visible until JavaOperationLower(1), so TCE must process
  // it directly instead of relying on an earlier expansion to check_instanceof.
  SmallVector<CallBase *, 16> Checks;
  for (auto &I : instructions(F)) {
    auto *CheckCB = dyn_cast<CallBase>(&I);
    Function *Callee = CheckCB ? CheckCB->getCalledFunction() : nullptr;
    if ((InstanceofFn && Callee == InstanceofFn) ||
        (KlassSubtypeFn && Callee == KlassSubtypeFn) ||
        (CheckCastFn && Callee == CheckCastFn))
      Checks.push_back(CheckCB);
  }

  bool Changed = false;
  for (CallBase *CheckCB : Checks) {
    Function *Callee = CheckCB->getCalledFunction();

    // check_klass_subtype takes two Klass operands, unlike
    // check_instanceof/checkcast which take (SuperKlass, oop).  Handle this
    // form before applying the generic JavaType-based oop logic below.
    if (Callee == KlassSubtypeFn) {
      uintptr_t SubKlass =
          jeandle::extractKlassConstant(CheckCB->getArgOperand(0));
      uintptr_t SuperKlass =
          jeandle::extractKlassConstant(CheckCB->getArgOperand(1));
      if (SubKlass == 0 || SuperKlass == 0)
        continue;

      if (CB->IsSubtype(SubKlass, SuperKlass)) {
        LLVM_DEBUG(dbgs() << "TCE: known klass subtype, replacing with true: "
                          << *CheckCB << "\n");
        CheckCB->replaceAllUsesWith(
            ConstantInt::getTrue(CheckCB->getType()));
        CheckCB->eraseFromParent();
        Changed = true;
      } else if (jeandle::areKlassesIncompatible(
                     SubKlass, /*KlassExact=*/true, SuperKlass)) {
        LLVM_DEBUG(dbgs() << "TCE: incompatible klasses, replacing with false: "
                          << *CheckCB << "\n");
        CheckCB->replaceAllUsesWith(
            ConstantInt::getFalse(CheckCB->getType()));
        CheckCB->eraseFromParent();
        Changed = true;
      }
      continue;
    }

    uintptr_t SuperKlass =
        jeandle::extractKlassConstant(CheckCB->getArgOperand(0));
    if (SuperKlass == 0)
      continue;

    const bool IsCheckcast = Callee == CheckCastFn;

    // --- Fold to true: instanceof/checkcast java.lang.Object ---
    // Every non-null object is an instance of Object. checkcast also succeeds
    // for null, so this replacement is valid for both helpers.
    if (CB->IsObjectKlass(SuperKlass)) {
      LLVM_DEBUG(dbgs() << "TCE: instanceof Object, replacing with true: "
                        << *CheckCB << "\n");
      CheckCB->replaceAllUsesWith(ConstantInt::getTrue(CheckCB->getType()));
      CheckCB->eraseFromParent();
      Changed = true;
      continue;
    }

    Value *Obj = CheckCB->getArgOperand(1);
    // A known subtype makes both helpers true: check_instanceof requires a
    // non-null oop, while checkcast also succeeds when its oop is null.
    jeandle::JavaType ObjType = jeandle::getJavaType(Obj, &DT, CheckCB);

    // --- Fold to true: known subtype ---
    if (ObjType.isKnown() && CB->IsSubtype(ObjType.Klass, SuperKlass)) {
      LLVM_DEBUG(dbgs() << "TCE: known subtype, replacing with true: "
                        << *CheckCB << "\n");
      CheckCB->replaceAllUsesWith(ConstantInt::getTrue(CheckCB->getType()));
      CheckCB->eraseFromParent();
      Changed = true;
      continue;
    }

    // --- Fold to false or null-test ---
    // JavaType does not model nullability. An incompatible checkcast therefore
    // becomes `oop == null`: null casts successfully, while the proven-
    // incompatible non-null case fails.
    bool FoldToFalse = false;

    if (ObjType.isKnown() &&
        jeandle::areKlassesIncompatible(ObjType.Klass, ObjType.Exact,
                                        SuperKlass)) {
      LLVM_DEBUG(dbgs() << "TCE: incompatible class types\n");
      if (IsCheckcast) {
        replaceCheckcastWithNullTest(CheckCB, Obj);
        Changed = true;
        continue;
      }
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
          if (IsCheckcast) {
            replaceCheckcastWithNullTest(CheckCB, Obj);
            Changed = true;
            break;
          }
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
