//===- Jeandle.h - Jeandle Compilation Interface --------------------------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef JEANDLE_JEANDLE_H
#define JEANDLE_JEANDLE_H

#include "llvm/IR/Module.h"
#include "llvm/Jeandle/Pipeline.h"
#include "llvm/Passes/OptimizationLevel.h"

namespace llvm::jeandle {

void optimize(Module &M, OptimizationLevel Level = OptimizationLevel::O3,
              PipelineMode Mode = PipelineMode::MethodCompilation);

} // end namespace llvm::jeandle

#endif // JEANDLE_JEANDLE_H
