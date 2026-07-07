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
#include "llvm/Transforms/Jeandle/JavaOperationDeletion.h"
#include "llvm/Transforms/Jeandle/JavaOperationLower.h"
#include "llvm/Transforms/Jeandle/JeandleInliner.h"
#include "llvm/Transforms/Jeandle/RepeatedConstantFolding.h"
#include "llvm/Transforms/Jeandle/TLSPointerRewrite.h"
#include "llvm/Transforms/Jeandle/TypeCheckElimination.h"
#include "llvm/Transforms/Scalar/InstSimplifyPass.h"
#include "llvm/Transforms/Scalar/RewriteStatepointsForGC.h"

namespace llvm::jeandle {

Pipeline::Pipeline(OptimizationLevel level, LLVMContext &Ctx,
                   PipelineOptions Options)
    : SI(Ctx, /*DebugLogging=*/false) {
  SI.registerCallbacks(PIC, &MAM);

  PassBuilder PB(nullptr, PipelineTuningOptions(), std::nullopt, &PIC);

  // Register all the basic analyses with the managers.
  PB.registerModuleAnalyses(MAM);
  PB.registerCGSCCAnalyses(CGAM);
  PB.registerFunctionAnalyses(FAM);
  PB.registerLoopAnalyses(LAM);
  PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);

  PM = buildJeandlePipeline(PB, level, Options);
}

// TODO: The pass selection/ordering is not optimal. We need to improve it.
ModulePassManager Pipeline::buildJeandlePipeline(PassBuilder &PB,
                                                 OptimizationLevel level,
                                                 PipelineOptions Options) {
  ModulePassManager PM;
  PM.addPass(JavaOperationLower(0));
  // JeandleInlineDriver owns the inline-specific loop. Devirtualization
  // refinement between inline rounds should be wired inside the driver so
  // inline-scope state can be preserved across IR rewrites.
  switch (Options.Inlining) {
  case InlineMode::Disabled:
    break;
  case InlineMode::Default:
    PM.addPass(JeandleInlineDriver());
    break;
  case InlineMode::AccessorOnly:
    PM.addPass(JeandleInlineDriver(/*InlineAccessorsOnly=*/true));
    break;
  }
  PM.addPass(createModuleToFunctionPassAdaptor(InstSimplifyPass()));
  PM.addPass(createModuleToFunctionPassAdaptor(TypeCheckElimination()));
  PM.addPass(createModuleToFunctionPassAdaptor(RepeatedConstantFolding()));
  PM.addPass(createModuleToFunctionPassAdaptor(TypeCheckElimination()));
  // TODO: InsertGCBarriers currently inserts high-level barrier calls before
  // O3 because it cannot handle O3 generated memory intrinsics and vector
  // instructions. But the uninlined barrier calls can still block useful
  // optimizations.
  PM.addPass(createModuleToFunctionPassAdaptor(InsertGCBarriers()));
  PM.addPass(JavaOperationLower(1));
  PM.addPass(std::move(PB.buildPerModuleDefaultPipeline(level)));
  PM.addPass(RewriteStatepointsForGC());
  // Phase 9 is reserved for JavaOps that must be lowered after O3/RS4GC.
  //
  // JavaOperationLower(9) lowers GC barriers only after O3/RS4GC. Lowered G1
  // barriers may compute raw addresses derived from oops, such as card-table
  // addresses. Those raw derived addresses are not oops, are not tracked by
  // RS4GC, and the JVM has no mechanism to update them if a safepoint moves
  // the source oop.
  //
  // The required invariant is that the def-use range of each such raw derived
  // address must not contain a safepoint. Lowering barriers too early exposes
  // the raw address computations to O3, which may extend or reuse them across
  // safepoints and break that invariant. Delaying only the lowering preserves
  // optimization opportunities while keeping raw derived addresses local to the
  // final barrier code.
  PM.addPass(JavaOperationLower(9));
  // Erase JavaOp definitions that have been fully lowered (user-empty) and are
  // no longer referenced. This must run after the inline driver and all
  // JavaOperationLower phases: every JavaOp must stay alive while replayed
  // callee bodies may still resolve them by name during inlining.
  PM.addPass(JavaOperationDeletion());
  PM.addPass(createModuleToFunctionPassAdaptor(TLSPointerRewrite()));
  PM.addPass(createModuleToFunctionPassAdaptor(InstSimplifyPass()));
  return PM;
}

void Pipeline::run(Module &M) { PM.run(M, MAM); }

} // end namespace llvm::jeandle
