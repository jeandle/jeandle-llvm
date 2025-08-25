//===- JavaOperationLower.cpp - Lower Java Operations ---------------------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/JavaOperationLower.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Debug.h"
#include "llvm/Transforms/Utils/Cloning.h"

using namespace llvm;

#define DEBUG_TYPE "java-operation-lower"

namespace {

static bool runImpl(Module &M, int Phase) {
  bool Changed = false;
  InlineFunctionInfo IFI;

  for (Function &F : M) {
    LLVM_DEBUG(dbgs() << "Searching in function: " << F.getName()
                      << " in lower phase: " << Phase << "\n");
    if (F.isDeclaration())
      continue;

    SmallVector<CallBase *, 16> CallInstructions;
    for (Instruction &I : instructions(F)) {
      if (auto *CB = dyn_cast<CallBase>(&I)) {
        // Skip instructions that are not lowered in this phase.
        Function *Callee = CB->getCalledFunction();
        if (!Callee || Callee->isDeclaration())
          continue;

        if (!Callee->hasFnAttribute(jeandle::Attribute::LowerPhase))
          continue;

        Attribute LowerPhase =
            Callee->getFnAttribute(jeandle::Attribute::LowerPhase);
        int LowerPhaseValue;
        bool Failed =
            LowerPhase.getValueAsString().getAsInteger(10, LowerPhaseValue);
        assert(!Failed && "wrong value of LowerPhase attribute");
        if (LowerPhaseValue != Phase)
          continue;

        CallInstructions.push_back(CB);
      }
    }

    // Inline
    for (CallBase *CB : CallInstructions) {
      Function *Callee = CB->getCalledFunction();
      if (InlineFunction(*CB, IFI).isSuccess()) {
        Changed = true;
        LLVM_DEBUG(dbgs() << "Successfully inlined: " << Callee->getName()
                          << " in lower phase: " << Phase << "\n");
      } else {
        LLVM_DEBUG(dbgs() << "Failed to inline: " << Callee->getName()
                          << " in lower phase: " << Phase << "\n");
      }
    }
  }

  return Changed;
}

} // end anonymous namespace

namespace llvm {

PreservedAnalyses JavaOperationLower::run(Module &M,
                                          ModuleAnalysisManager &MAM) {
  // TODO: Just a workaround here. A more efficient algorithm is needed in later
  // work.

  bool Changed = false;
  while (runImpl(M, Phase)) {
    Changed = true;
  }

  // Remove unused functions.
  SmallVector<Function *> FunctionsToRemove;
  for (Function &F : M) {
    if (!F.hasFnAttribute(jeandle::Attribute::LowerPhase))
      continue;
    Attribute LowerPhase = F.getFnAttribute(jeandle::Attribute::LowerPhase);
    int LowerPhaseValue;
    bool Failed =
        LowerPhase.getValueAsString().getAsInteger(10, LowerPhaseValue);
    assert(!Failed && "wrong value of LowerPhase attribute");
    if (LowerPhaseValue == Phase) {
      FunctionsToRemove.push_back(&F);
    }
  }
  for (Function *F : FunctionsToRemove) {
    LLVM_DEBUG(dbgs() << "Remove unused function: " << F->getName()
                      << " in lower phase: " << Phase << "\n");
    F->eraseFromParent();
    Changed = true;
  }

  if (!Changed)
    return PreservedAnalyses::all();
  return PreservedAnalyses::none();
}

} // end namespace llvm
