//===- PEAOptimizer.h - PEA Optimizer Interface --------------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_PEA_OPTIMIZER_H
#define LLVM_TRANSFORMS_JEANDLE_PEA_OPTIMIZER_H

#include "llvm/Transforms/Jeandle/PEA/PEATransformManager.h"
#include "llvm/Analysis/Jeandle/PartialEscapeAnalysis.h"
#include "llvm/IR/Function.h"
#include "llvm/ADT/StringRef.h"

namespace llvm::jeandle {

class PEAOptimizer {
public:
  virtual ~PEAOptimizer() = default;

  virtual void collect(Function &F, PEAResult &EA, PEATransformManager &TM) = 0;

  virtual StringRef getName() const = 0;
};

} // namespace llvm::jeandle

#endif // LLVM_TRANSFORMS_JEANDLE_PEA_OPTIMIZER_H
