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
#include "llvm/IR/PassManager.h"
#include "llvm/Transforms/InstCombine/InstCombine.h"
#include "llvm/Transforms/Jeandle/CHADevirtualization.h"
#include "llvm/Transforms/Jeandle/ExpandNarrowOopCast.h"
#include "llvm/Transforms/Jeandle/InsertGCBarriers.h"
#include "llvm/Transforms/Jeandle/JavaOperationDeletion.h"
#include "llvm/Transforms/Jeandle/JavaOperationLower.h"
#include "llvm/Transforms/Jeandle/JeandleInliner.h"
#include "llvm/Transforms/Jeandle/JeandleNarrowOopMarker.h"
#include "llvm/Transforms/Jeandle/RecoverTypeInfo.h"
#include "llvm/Transforms/Jeandle/RepeatedConstantFolding.h"
#include "llvm/Transforms/Jeandle/SafepointCoverageVerifier.h"
#include "llvm/Transforms/Jeandle/SafepointPollElimination.h"
#include "llvm/Transforms/Jeandle/SafepointStripMining.h"
#include "llvm/Transforms/Jeandle/SafepointUtils.h"
#include "llvm/Transforms/Jeandle/TLSPointerRewrite.h"
#include "llvm/Transforms/Jeandle/TypeCheckElimination.h"
#include "llvm/Transforms/Scalar/ADCE.h"
#include "llvm/Transforms/Scalar/EarlyCSE.h"
#include "llvm/Transforms/Scalar/IndVarSimplify.h"
#include "llvm/Transforms/Scalar/InstSimplifyPass.h"
#include "llvm/Transforms/Scalar/LICM.h"
#include "llvm/Transforms/Scalar/LoopRotation.h"
#include "llvm/Transforms/Scalar/RewriteStatepointsForGC.h"
#include "llvm/Transforms/Scalar/SimplifyCFG.h"
#include "llvm/Transforms/Utils/LCSSA.h"

namespace llvm::jeandle {

Pipeline::Pipeline(OptimizationLevel Level, LLVMContext &Ctx,
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

  PM = buildJeandlePipeline(PB, Level, Options);
}

// TODO: The pass selection/ordering is not optimal. We need to improve it.

// Append the safepoint coverage verifier when it is not disabled.
static void addCoverageVerifier(ModulePassManager &PM) {
  if (getSafepointCoverageCheck() != SafepointCoverageCheck::Off)
    PM.addPass(createModuleToFunctionPassAdaptor(SafepointCoverageVerifier()));
}

// Prepare strip-mining candidates by exposing array-length exits and scalar
// comparisons, then hoisting guaranteed invariant header work before rotation
// applies its duplication budget. The second, speculative LICM cleans up the
// rotated loop. FunctionToLoopPassAdaptor establishes LoopSimplify and LCSSA
// form before running the loop pipeline.
static void addPreparationForStripMining(ModulePassManager &PM) {
  PM.addPass(createModuleToFunctionPassAdaptor(EarlyCSEPass()));
  PM.addPass(createModuleToFunctionPassAdaptor(InstCombinePass()));
  PM.addPass(createModuleToFunctionPassAdaptor(SimplifyCFGPass()));
  LoopPassManager LPM;
  LICMOptions PreRotateLICMOptions;
  PreRotateLICMOptions.AllowSpeculation = false;
  LPM.addPass(LICMPass(PreRotateLICMOptions));
  LPM.addPass(LoopRotatePass(true, false));
  LPM.addPass(LICMPass(LICMOptions()));
  // IndVarSimplify canonicalizes the IV and strengthens SCEV no-wrap flags (via
  // SimplifyIndVar's getStrengthenedNoWrapFlagsFromBinOp), so the strip-mining
  // no-wrap proofs can rely on SCEV flags instead of hand-derived bounds.
  LPM.addPass(IndVarSimplifyPass());
  PM.addPass(createModuleToFunctionPassAdaptor(
      createFunctionToLoopPassAdaptor(std::move(LPM), true)));
}

// Inclusive loop versioning (optional) then strip mining, followed by the
// coverage verifier. The InclusiveLoopVersioning mode clones runtime-risk
// inclusive loops behind a no-wrap guard; StripMining then relocates each
// candidate's back-edge poll to an outer back-edge.
static void addStripMiningPasses(ModulePassManager &PM,
                                 bool DeferEmptyLoopDeletion) {
  if (isInclusiveLoopVersioningEnabled())
    PM.addPass(createModuleToFunctionPassAdaptor(
        SafepointStripMining(SafepointStripMiningMode::InclusiveLoopVersioning,
                             DeferEmptyLoopDeletion)));
  PM.addPass(createModuleToFunctionPassAdaptor(SafepointStripMining(
      SafepointStripMiningMode::StripMining, DeferEmptyLoopDeletion)));
  PM.addPass(createModuleToFunctionPassAdaptor(SafepointPollElimination(
      SafepointPollEliminationMode::AfterStripMining, DeferEmptyLoopDeletion)));
  addCoverageVerifier(PM);
}

ModulePassManager Pipeline::buildJeandlePipeline(PassBuilder &PB,
                                                 OptimizationLevel Level,
                                                 PipelineOptions Options) {
  ModulePassManager PM;
  PM.addPass(JavaOperationLower(0));
  FunctionPassManager PreCHACleanup;
  PreCHACleanup.addPass(InstSimplifyPass());
  PreCHACleanup.addPass(RecoverTypeInfo());
  PreCHACleanup.addPass(TypeCheckElimination());
  PreCHACleanup.addPass(RepeatedConstantFolding());
  PreCHACleanup.addPass(EarlyCSEPass());
  PreCHACleanup.addPass(InstCombinePass());
  PreCHACleanup.addPass(SimplifyCFGPass());
  PreCHACleanup.addPass(ADCEPass());
  PM.addPass(createModuleToFunctionPassAdaptor(std::move(PreCHACleanup)));
  PM.addPass(createModuleToFunctionPassAdaptor(RecoverTypeInfo()));
  PM.addPass(createModuleToFunctionPassAdaptor(CHADevirtualization()));
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
  // RecoverTypeInfo re-attaches !java-klass metadata stripped by the inline
  // driver's load CSE (EarlyCSE/InstCombine) before each TypeCheckElimination
  // round so TCE sees the recovered declared field types.
  PM.addPass(createModuleToFunctionPassAdaptor(RecoverTypeInfo()));
  PM.addPass(createModuleToFunctionPassAdaptor(TypeCheckElimination()));
  PM.addPass(createModuleToFunctionPassAdaptor(RepeatedConstantFolding()));
  PM.addPass(createModuleToFunctionPassAdaptor(TypeCheckElimination()));

  const bool StripMiningEnabled = isStripMiningEnabled();
  const bool DeferEmptyLoopDeletion = (Level == OptimizationLevel::O3);

  // The loop adaptor establishes LoopSimplify + LCSSA form before
  // IndVarSimplify or the strip-mining canonicalization pipeline. On the
  // strip-mining-OFF path, IndVarSimplify also strengthens SCEV no-wrap flags
  // on the frontend's bare (flagless) IV increments, so Early can prove that a
  // loop's maximum backedge count is strictly below INT_MAX
  // (IsIntCountedEquivalent) and drop all of its polls.
  if (StripMiningEnabled) {
    addPreparationForStripMining(PM);
  } else {
    LoopPassManager LPM;
    LPM.addPass(IndVarSimplifyPass());
    PM.addPass(createModuleToFunctionPassAdaptor(
        createFunctionToLoopPassAdaptor(std::move(LPM))));
  }

  // With strip mining enabled, Early handles only non-loop blocks. Loop polls
  // remain available to strip mining, then AfterStripMining performs the full
  // loop-tree deletion. Without strip mining, Early also performs that loop
  // deletion directly.
  PM.addPass(createModuleToFunctionPassAdaptor(SafepointPollElimination(
      SafepointPollEliminationMode::Early, DeferEmptyLoopDeletion)));
  addCoverageVerifier(PM);

  if (StripMiningEnabled)
    addStripMiningPasses(PM, DeferEmptyLoopDeletion);

  // TODO: InsertGCBarriers currently inserts high-level barrier calls before
  // O3 because it cannot handle O3 generated memory intrinsics and vector
  // instructions. But the uninlined barrier calls can still block useful
  // optimizations.
  PM.addPass(createModuleToFunctionPassAdaptor(InsertGCBarriers()));

  if (DeferEmptyLoopDeletion) {
    // Re-form LCSSA independently of strip mining, then atomically delete
    // finite empty loops and the polls that prevent their deletion.
    PM.addPass(createModuleToFunctionPassAdaptor(LCSSAPass()));
    PM.addPass(createModuleToFunctionPassAdaptor(SafepointPollElimination(
        SafepointPollEliminationMode::LoopDeletionPrep)));
  }

  PM.addPass(JavaOperationLower(1));
  PM.addPass(std::move(PB.buildPerModuleDefaultPipeline(Level)));
  PM.addPass(ExpandNarrowOopCast());
  PM.addPass(RewriteStatepointsForGC());
  PM.addPass(createModuleToFunctionPassAdaptor(JeandleNarrowOopMarker()));
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
