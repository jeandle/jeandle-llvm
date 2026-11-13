//===- SafepointPollNormalization.cpp - Nonthrowing polls ---------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/SafepointPollNormalization.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"
#include "llvm/Transforms/Utils/Local.h"

using namespace llvm;

PreservedAnalyses SafepointPollNormalization::run(Function &F,
                                                  FunctionAnalysisManager &AM) {
  const Function *PollFunction =
      F.getParent()->getFunction("jeandle.safepoint_poll");
  if (!PollFunction)
    return PreservedAnalyses::all();
  bool Changed = false;
  for (BasicBlock &BB : F) {
    for (Instruction &I : make_early_inc_range(BB)) {
      auto *Poll = dyn_cast<CallBase>(&I);
      if (!Poll || isa<CallBrInst>(Poll) ||
          Poll->getCalledFunction() != PollFunction)
        continue;
      // Polls can collect and deoptimize, but async exceptions are deferred
      // to the interpreter. Inlining into an invoke must not add EH exits.
      if (auto *Invoke = dyn_cast<InvokeInst>(Poll)) {
        Poll = changeToCall(Invoke);
        Changed = true;
      }
      if (!Poll->hasFnAttr(Attribute::NoUnwind)) {
        Poll->setDoesNotThrow();
        Changed = true;
      }
    }
  }
  return Changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
}
