//===- JavaOperationDeletion.cpp - Erase lowered JavaOps -------------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/JavaOperationDeletion.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Debug.h"

using namespace llvm;

#define DEBUG_TYPE "java-operation-deletion"

namespace {

// Strip \p F from the @llvm.used global array so it can be erased without
// leaving a dangling Constant reference that would trip the verifier. Returns
// true if @llvm.used was modified. Moved here from JavaOperationLower: lowering
// no longer erases JavaOps, so only this deletion pass needs the helper.
static bool removeFunctionFromLLVMUsed(Module &M, Function &F) {
  GlobalVariable *UsedArray = M.getGlobalVariable("llvm.used");
  if (!UsedArray)
    return false;

  ConstantArray *InitArray = cast<ConstantArray>(UsedArray->getInitializer());
  if (!InitArray) {
    UsedArray->eraseFromParent();
    return false;
  }

  std::vector<Constant *> NewElements;
  bool found = false;

  // Find all elements to be preserved.
  for (unsigned i = 0; i < InitArray->getNumOperands(); i++) {
    Constant *Element = InitArray->getOperand(i);
    if (Function *Func = dyn_cast<Function>(Element)) {
      if (Func == &F) {
        found = true;
        continue;
      }
    }
    NewElements.push_back(Element);
  }

  if (!found)
    return false;

  UsedArray->eraseFromParent();

  // Erase the empty llvm.used directly.
  if (NewElements.empty())
    return true;

  // Create a new llvm.used with the preserved elements.
  auto *NewArrayTy = ArrayType::get(InitArray->getType()->getElementType(),
                                    NewElements.size());

  auto *NewUsedArray = new GlobalVariable(
      M, NewArrayTy, false, GlobalValue::AppendingLinkage,
      ConstantArray::get(NewArrayTy, NewElements), "llvm.used");
  NewUsedArray->setSection("llvm.metadata");

  return true;
}

} // end anonymous namespace

PreservedAnalyses JavaOperationDeletion::run(Module &M, ModuleAnalysisManager &MAM) {
  bool Changed = false;
  FunctionAnalysisManager &FAM =
      MAM.getResult<FunctionAnalysisManagerModuleProxy>(M).getManager();

  for (Function &F : make_early_inc_range(M)) {
    if (!F.hasFnAttribute(jeandle::Attribute::LowerPhase))
      continue;
    // JavaOps are definitions; a declaration with a lower-phase attribute would
    // be malformed input. Skip defensively rather than risk erasing a prototype
    // that may still be referenced.
    if (F.isDeclaration())
      continue;

    // Strip @llvm.used first: a lowered JavaOp that no longer has any caller is
    // still referenced by the @llvm.used global, so user_empty() is false until
    // that reference is removed. This mirrors the order the old JavaOperationLower
    // used (strip, then check emptiness, then erase). If F survives (it still has
    // real users) it does not need @llvm.used protection, since real callers keep
    // it alive against DCE on their own.
    bool Stripped = removeFunctionFromLLVMUsed(M, F);
    F.removeDeadConstantUsers();

    // A JavaOp that still has real users (e.g. an un-driven phase, or residual
    // non-call ConstantExpr/metadata uses) has not been fully lowered. Leave it
    // in place so we never delete a definition that is still referenced.
    if (!F.user_empty()) {
      Changed |= Stripped;
      continue;
    }

    LLVM_DEBUG(dbgs() << "erase lowered JavaOp: " << F.getName() << "\n");

    FAM.clear(F, F.getName());
    M.getFunctionList().erase(F);
    Changed = true;
  }

  if (!Changed)
    return PreservedAnalyses::all();

  PreservedAnalyses PA;
  PA.preserve<FunctionAnalysisManagerModuleProxy>();
  PA.preserveSet<AllAnalysesOn<Function>>();
  return PA;
}
