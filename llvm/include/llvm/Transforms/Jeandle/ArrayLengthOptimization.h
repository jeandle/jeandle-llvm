//===- ArrayLengthOptimization.h - Immutable Java array lengths ---*- C++
//-*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_ARRAYLENGTHOPTIMIZATION_H
#define LLVM_TRANSFORMS_JEANDLE_ARRAYLENGTHOPTIMIZATION_H

#include "llvm/IR/PassManager.h"

namespace llvm {

class ArrayLengthOptimization : public PassInfoMixin<ArrayLengthOptimization> {
public:
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM);
};

} // namespace llvm

#endif
