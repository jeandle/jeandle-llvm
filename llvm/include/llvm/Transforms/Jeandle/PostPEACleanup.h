//===- PostPEACleanup.h - Clean up compiler markers after PEA -*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Remove compiler-only materialization JavaOps and sideeffect markers after
// every PEA iteration has completed, or when PEA is disabled. Markers must
// remain live during the iterative analysis and disappear before subsequent
// scalar/loop optimization.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_POSTPEACLEANUP_H
#define LLVM_TRANSFORMS_JEANDLE_POSTPEACLEANUP_H

#include "llvm/IR/PassManager.h"

namespace llvm {

class PostPEACleanup : public PassInfoMixin<PostPEACleanup> {
public:
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM);
};

} // namespace llvm

#endif // LLVM_TRANSFORMS_JEANDLE_POSTPEACLEANUP_H
