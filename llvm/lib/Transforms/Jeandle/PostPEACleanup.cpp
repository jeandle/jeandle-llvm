//===- PostPEACleanup.cpp - Clean up compiler markers after PEA ----------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/PostPEACleanup.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/Support/Debug.h"

using namespace llvm;

#define DEBUG_TYPE "post-pea-cleanup"

namespace {

constexpr StringLiteral EnsureMaterializedForStackWalk =
    "jeandle.ensure_materialized_for_stack_walk";

static Function *getDirectCallee(const CallBase &CB) {
  return dyn_cast<Function>(CB.getCalledOperand()->stripPointerCasts());
}

} // namespace

PreservedAnalyses PostPEACleanup::run(Function &F, FunctionAnalysisManager &) {
  SmallVector<CallInst *, 2> CallsToErase;

  for (Instruction &I : instructions(F)) {
    auto *CI = dyn_cast<CallInst>(&I);
    if (!CI)
      continue;

    if (CI->getIntrinsicID() == Intrinsic::sideeffect &&
        CI->getOperandBundle("jeandle.pea.materialize")) {
      CallsToErase.push_back(CI);
      continue;
    }

    Function *Callee = getDirectCallee(*CI);
    if (Callee && Callee->getName() == EnsureMaterializedForStackWalk) {
      LLVM_DEBUG(dbgs() << "PostPEACleanup: erase " << *CI << "\n");
      CallsToErase.push_back(CI);
    }
  }

  for (CallInst *CI : CallsToErase)
    CI->eraseFromParent();

  if (CallsToErase.empty())
    return PreservedAnalyses::all();
  return PreservedAnalyses::none();
}
