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
#include "llvm/Transforms/Utils/Cloning.h"
#include <utility>
#include <set>

using namespace llvm;
using namespace llvm::jeandle;

#define DEBUG_TYPE "java-operation-lower"

namespace {
static bool runImpl(Module &M, int Phase) {
  bool Changed = false;
  InlineFunctionInfo IFI;
  bool LocalChanged = false;
  std::set<std::pair<const Function *, const Function *>> Seen;
  
  auto isPhaseFunc = [&](const Function &F) -> bool {
    if (!F.hasFnAttribute(attr::LowerPhase))
      return false;
    int V = 0;
    bool Failed = F.getFnAttribute(attr::LowerPhase)
                      .getValueAsString()
                      .getAsInteger(10, V);
    assert(!Failed && "wrong value of LowerPhase attribute");
    return V == Phase;
  };

  do {
    LocalChanged = false;
    for (Function &F : M) {
      if (F.isDeclaration())
        continue;
      SmallVector<CallBase *, 16> CallInstructions;
      CallInstructions.clear();

      // Collect direct calls to functions of the current phase within the
      // current function
      for (Instruction &I : instructions(F)) {
        auto *CB = dyn_cast<CallBase>(&I);
        if (!CB)
          continue;

        Function *Callee = CB->getCalledFunction();
        if (!Callee || Callee->isDeclaration())
          continue;

        if (!isPhaseFunc(*Callee))
          continue;

        // Skip self-recursion to avoid attempting again on itself after
        // inlining
        std::pair<const Function *, const Function *> Key{Callee, &F};
        if (Seen.find(Key) != Seen.end()) {
          continue;
        }
        Seen.insert(Key);
        CallInstructions.push_back(CB);
      }
      // Inline the collected call sites
      for (CallBase *CB : CallInstructions) {
        // Record the name to avoid dangling pointers after inlining
        Function *Callee = CB->getCalledFunction();
        StringRef CalleeName = Callee ? Callee->getName() : StringRef();
        InlineResult IR = InlineFunction(*CB, IFI);
        if (IR.isSuccess()) {
          LocalChanged = true;
          LLVM_DEBUG(dbgs()
                     << "Successfully inlined: " << CalleeName << " into "
                     << F.getName() << " in lower phase: " << Phase << "\n");
        } else {
          LLVM_DEBUG(dbgs() << "Failed to inline: " << CalleeName << " into "
                            << F.getName() << " in lower phase: " << Phase
                            << " reason: " << IR.message() << "\n");
        }
      }
    }
    Changed |= LocalChanged;
  } while (LocalChanged);

  SmallVector<Function *, 16> FunctionsToRemove;
  // Remove unused functions.
  for (Function &F : M) {
    // Keep if called by functions of different phases
    if (F.use_empty() && isPhaseFunc(F)) {
      assert(!F.hasFnAttribute(attr::JavaMethod) &&
             "inlined function should not be java method");
      FunctionsToRemove.push_back(&F);
    }
  }
  for (Function *F : FunctionsToRemove) {
    LLVM_DEBUG(dbgs() << "Remove unused function: " << F->getName()
                      << " in lower phase: " << Phase << "\n");
    F->eraseFromParent();
    Changed = true;
  }

  return Changed;
}

} // end anonymous namespace

namespace llvm {

PreservedAnalyses JavaOperationLower::run(Module &M,
                                          ModuleAnalysisManager &MAM) {
  if (!runImpl(M, Phase))
    return PreservedAnalyses::all();
  return PreservedAnalyses::none();
}

} // end namespace llvm
