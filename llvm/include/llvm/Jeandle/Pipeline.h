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
#include "llvm/Passes/StandardInstrumentations.h"
#include "llvm/Support/Compiler.h"
#include "llvm/Transforms/Jeandle/JavaOperationLower.h"

namespace llvm::jeandle {

// Controls whether JeandleInliner is added and which callees it may try.
enum class InlineMode {
  Disabled,
  Default,
  AccessorOnly,
};

struct PipelineOptions {
  InlineMode Inlining = InlineMode::Default;
};

class Pipeline {
public:
  Pipeline(OptimizationLevel Level, LLVMContext &Ctx,
           PipelineOptions Options = {});

  LLVM_ABI static ModulePassManager
  buildJeandlePipeline(PassBuilder &PB, OptimizationLevel Level,
                       PipelineOptions Options = {});

  void run(Module &M);

private:
  PassInstrumentationCallbacks PIC;
  StandardInstrumentations SI;
  ModulePassManager PM;
  LoopAnalysisManager LAM;
  CGSCCAnalysisManager CGAM;
  FunctionAnalysisManager FAM;
  ModuleAnalysisManager MAM;
};

} // end namespace llvm::jeandle

#endif // JEANDLE_PIPELINE_H
