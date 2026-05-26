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
#include "llvm/Transforms/Jeandle/SafepointElimination.h"
#include "llvm/Transforms/Jeandle/TLSPointerRewrite.h"
#include "llvm/Transforms/Jeandle/TypeCheckElimination.h"
#include "llvm/Transforms/Scalar/EarlyCSE.h"
#include "llvm/Transforms/Scalar/InstSimplifyPass.h"
#include "llvm/Transforms/Scalar/LoopPassManager.h"
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

  // EarlyCSE hoists loop-invariant calls like `jeandle.arraylength` out of
  // counted loops so that SCEV sees a loop-invariant exit bound. Without this
  // the bound classification below would not fire on most Java array loops.
  PM.addPass(createModuleToFunctionPassAdaptor(EarlyCSEPass()));
  // Safepoint elimination on counted loops. Driven via the LPM adaptor so
  // that LoopSimplify and LCSSA canonicalize loops before us, and so a future
  // strip-mining transform can register newly-created outer loops with the
  // LPMUpdater. Placed before the default pipeline so LoopVectorize / LICM
  // see poll-free inner loops.
  PM.addPass(createModuleToFunctionPassAdaptor(
      createFunctionToLoopPassAdaptor(SafepointElimination())));

  PM.addPass(std::move(PB.buildPerModuleDefaultPipeline(level)));
  PM.addPass(createModuleToFunctionPassAdaptor(InsertGCBarriers()));
  PM.addPass(JavaOperationLower(1));
  PM.addPass(createModuleToFunctionPassAdaptor(TLSPointerRewrite()));
  PM.addPass(RewriteStatepointsForGC());
  return PM;
}

void Pipeline::run(Module &M) { PM.run(M, MAM); }

} // end namespace llvm::jeandle
