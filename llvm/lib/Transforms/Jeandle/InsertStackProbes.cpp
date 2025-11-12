//===- InsertStackProbes.cpp ---------------------------------------------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/InsertStackProbes.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Jeandle/GCStrategy.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Debug.h"
#include "llvm/TargetParser/Triple.h"

using namespace llvm;

#define DEBUG_TYPE "insert-stack-probes"

namespace {

constexpr StringLiteral ProbeStackHandler =
    "stubRoutines::throw_stack_overflow";

bool isSupportedTarget(const Triple &TT) {
  return TT.isX86() || TT.isAArch64();
}

bool isJavaMethod(Function &F) {
  if (F.isDeclaration())
    return false;
  if (F.getCallingConv() != CallingConv::Hotspot_JIT)
    return false;
  return F.hasGC() && jeandle::isJeandleGC(F.getGC());
}

} // namespace

PreservedAnalyses InsertStackProbes::run(Module &M, ModuleAnalysisManager &) {
  if (!M.getNamedMetadata(jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();

  Triple TT(M.getTargetTriple());
  if (!isSupportedTarget(TT))
    return PreservedAnalyses::all();

  bool Changed = false;
  for (Function &F : M) {
    if (!isJavaMethod(F))
      continue;
    if (F.hasFnAttribute("probe-stack"))
      continue;

    LLVM_DEBUG(dbgs() << "Adding probe-stack to " << F.getName() << "\n");
    F.addFnAttr("probe-stack", ProbeStackHandler);
    Changed = true;
  }

  if (!Changed)
    return PreservedAnalyses::all();

  return PreservedAnalyses::none();
}
