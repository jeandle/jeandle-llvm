//===- Jeandle.cpp - Jeandle Compilation Interface ------------------------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Jeandle/Jeandle.h"
#include "llvm/IR/Module.h"

namespace llvm::jeandle {

void optimize(Module &M, OptimizationLevel Level, PipelineMode Mode) {
  Pipeline P(Level, M.getContext(), Mode);
  P.run(M);
}

} // end namespace llvm::jeandle
