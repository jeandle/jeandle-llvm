//===- Pipeline.cpp - Jeandle Pipeline ------------------------------------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Jeandle/Pipeline.h"
#include "llvm/Transforms/Jeandle/InsertGCBarriers.h"
#include "llvm/Transforms/Jeandle/JavaOperationLower.h"
#include "llvm/Transforms/Jeandle/TLSPointerRewrite.h"
#include "llvm/Transforms/Scalar/RewriteStatepointsForGC.h"

namespace llvm::jeandle {

Pipeline::Pipeline(OptimizationLevel level) {
  // Create the new pass manager builder.
  // Take a look at the PassBuilder constructor parameters for more
  // customization, e.g. specifying a TargetMachine or various debugging
  // options.
  PassBuilder PB;

  // Register all the basic analyses with the managers.
  PB.registerModuleAnalyses(MAM);
  PB.registerCGSCCAnalyses(CGAM);
  PB.registerFunctionAnalyses(FAM);
  PB.registerLoopAnalyses(LAM);
  PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);

  buildJeandlePipeline(PM, PB, level);
}

void Pipeline::buildJeandlePipeline(ModulePassManager &PM, PassBuilder &PB,
                                    OptimizationLevel level) {
  PM.addPass(JavaOperationLower(0));
  PM.addPass(std::move(PB.buildPerModuleDefaultPipeline(level)));
  PM.addPass(createModuleToFunctionPassAdaptor(InsertGCBarriers()));
  PM.addPass(JavaOperationLower(1));
  PM.addPass(createModuleToFunctionPassAdaptor(TLSPointerRewrite()));
  PM.addPass(RewriteStatepointsForGC());
}

void Pipeline::run(Module &M) { PM.run(M, MAM); }

} // end namespace llvm::jeandle
