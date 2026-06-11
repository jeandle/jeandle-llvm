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
#include "llvm/Transforms/Jeandle/ConstantFieldFolding.h"
#include "llvm/Transforms/Jeandle/InsertGCBarriers.h"
#include "llvm/Transforms/Jeandle/JavaOperationLower.h"
#include "llvm/Transforms/Jeandle/TLSPointerRewrite.h"
#include "llvm/Transforms/Jeandle/TypeCheckElimination.h"
#include "llvm/Transforms/Scalar/InstSimplifyPass.h"
#include "llvm/Transforms/Scalar/RewriteStatepointsForGC.h"

namespace llvm::jeandle {

Pipeline::Pipeline(OptimizationLevel level, LLVMContext &Ctx)
    : SI(Ctx, /*DebugLogging=*/false) {
  SI.registerCallbacks(PIC, &MAM);

  PassBuilder PB(nullptr, PipelineTuningOptions(), std::nullopt, &PIC);

  // Register all the basic analyses with the managers.
  PB.registerModuleAnalyses(MAM);
  PB.registerCGSCCAnalyses(CGAM);
  PB.registerFunctionAnalyses(FAM);
  PB.registerLoopAnalyses(LAM);
  PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);

  PM = buildJeandlePipeline(PB, level);
}

ModulePassManager Pipeline::buildJeandlePipeline(PassBuilder &PB,
                                                 OptimizationLevel level) {
  ModulePassManager PM;
  PM.addPass(JavaOperationLower(0));
  PM.addPass(createModuleToFunctionPassAdaptor(InstSimplifyPass()));
  PM.addPass(createModuleToFunctionPassAdaptor(TypeCheckElimination()));
  PM.addPass(createModuleToFunctionPassAdaptor(ConstantFieldFolding()));
  PM.addPass(std::move(PB.buildPerModuleDefaultPipeline(level)));
  PM.addPass(createModuleToFunctionPassAdaptor(InsertGCBarriers()));
  PM.addPass(JavaOperationLower(1));
  PM.addPass(createModuleToFunctionPassAdaptor(TLSPointerRewrite()));
  PM.addPass(RewriteStatepointsForGC());
  return PM;
}

void Pipeline::run(Module &M) { PM.run(M, MAM); }

} // end namespace llvm::jeandle
