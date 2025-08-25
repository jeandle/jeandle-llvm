//===- Pipeline.h - Jeandle Pipeline --------------------------------------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef JEANDLE_PIPELINE_H
#define JEANDLE_PIPELINE_H

#include "llvm/IR/PassManager.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Transforms/Jeandle/JavaOperationLower.h"

namespace llvm::jeandle {

class Pipeline {
public:
  Pipeline(OptimizationLevel Level);

  static void buildJeandlePipeline(ModulePassManager &PM, PassBuilder &PB,
                                   OptimizationLevel Level);

  void run(Module &M);

private:
  ModulePassManager PM;
  LoopAnalysisManager LAM;
  CGSCCAnalysisManager CGAM;
  FunctionAnalysisManager FAM;
  ModuleAnalysisManager MAM;
};

} // end namespace llvm::jeandle

#endif // JEANDLE_PIPELINE_H
