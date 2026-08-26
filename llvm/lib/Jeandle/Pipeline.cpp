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
#include "llvm/Support/CommandLine.h"
#include "llvm/Transforms/InstCombine/InstCombine.h"
#include "llvm/Transforms/Jeandle/ArrayCopySpecialization.h"
#include "llvm/Transforms/Jeandle/CHADevirtualization.h"
#include "llvm/Transforms/Jeandle/ExpandNarrowOopCast.h"
#include "llvm/Transforms/Jeandle/InsertGCBarriers.h"
#include "llvm/Transforms/Jeandle/JavaOpLengthFolding.h"
#include "llvm/Transforms/Jeandle/JavaOperationDeletion.h"
#include "llvm/Transforms/Jeandle/JavaOperationLower.h"
#include "llvm/Transforms/Jeandle/JeandleInliner.h"
#include "llvm/Transforms/Jeandle/JeandleNarrowOopMarker.h"
#include "llvm/Transforms/Jeandle/PartialEscapeIterative.h"
#include "llvm/Transforms/Jeandle/PartialEscapeTransform.h"
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
#include "llvm/Transforms/Scalar/GVN.h"
#include "llvm/Transforms/Scalar/IndVarSimplify.h"
#include "llvm/Transforms/Scalar/InstSimplifyPass.h"
#include "llvm/Transforms/Scalar/LICM.h"
#include "llvm/Transforms/Scalar/LoopDeletion.h"
#include "llvm/Transforms/Scalar/LoopPassManager.h"
#include "llvm/Transforms/Scalar/LoopRotation.h"
#include "llvm/Transforms/Scalar/LoopUnrollPass.h"
#include "llvm/Transforms/Scalar/RewriteStatepointsForGC.h"
#include "llvm/Transforms/Scalar/SimpleLoopUnswitch.h"
#include "llvm/Transforms/Scalar/SimplifyCFG.h"
#include "llvm/Transforms/Utils/LCSSA.h"
#include "llvm/Transforms/Utils/LoopSimplify.h"

namespace llvm::jeandle {

// Trip-count cap for the pre-PEA full-unroll pass. Aligned with
// -jeandle-pea-max-array-length (default 128): loops bounded by a
// virtualizable array's length should fully unroll so PEA sees
// straight-line, constant-offset element accesses.
static cl::opt<unsigned> JeandlePrePEAFullUnrollMaxCount(
    "jeandle-pre-pea-full-unroll-max-count", cl::init(128), cl::Hidden,
    cl::desc("Pre-PEA: max trip count eligible for full unrolling in the "
             "high-tier cluster. Default 128, matching "
             "-jeandle-pea-max-array-length."));

namespace {

// Inlining policy for Java method compilation.
enum class InlinePolicy { Off, Default, AccessorsOnly };

} // namespace

// The JDK derives this from the Inline/InlineAccessors VM flags. Stub
// compilation never inlines regardless of this setting.
static cl::opt<InlinePolicy> JeandleInlinePolicy(
    "jeandle-inline", cl::init(InlinePolicy::Default), cl::Hidden,
    cl::desc("Inlining policy for Jeandle Java method compilation."),
    cl::values(clEnumValN(InlinePolicy::Default, "default", "Inline normally"),
               clEnumValN(InlinePolicy::AccessorsOnly, "accessors-only",
                          "Inline accessor methods only"),
               clEnumValN(InlinePolicy::Off, "off", "Disable inlining")));

Pipeline::Pipeline(OptimizationLevel Level, LLVMContext &Ctx, PipelineMode Mode)
    : SI(Ctx, /*DebugLogging=*/false) {
  SI.registerCallbacks(PIC, &MAM);

  PassBuilder PB(nullptr, PipelineTuningOptions(), std::nullopt, &PIC);

  // Register all the basic analyses with the managers.
  PB.registerModuleAnalyses(MAM);
  PB.registerCGSCCAnalyses(CGAM);
  PB.registerFunctionAnalyses(FAM);
  PB.registerLoopAnalyses(LAM);
  PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);

  PM = buildJeandlePipeline(PB, Level, Mode);
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
                                                 PipelineMode Mode) {
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
  // inline-scope state can be preserved across IR rewrites. Stub compilation
  // never inlines.
  if (Mode == PipelineMode::MethodCompilation) {
    switch (JeandleInlinePolicy) {
    case InlinePolicy::Off:
      break;
    case InlinePolicy::Default:
      PM.addPass(JeandleInlineDriver());
      break;
    case InlinePolicy::AccessorsOnly:
      PM.addPass(JeandleInlineDriver(/*InlineAccessorsOnly=*/true));
      break;
    }
  }
  // ==== PEA segment ====
  // Everything below up to InsertGCBarriers exists to serve PEA: the
  // high-tier loop-optimization cluster that exposes virtualization
  // opportunities, the pre-PEA cleanup that PEA's correctness depends on,
  // PEA itself, and the post-PEA cleanup. The whole segment is gated on
  // -jeandle-pea and the configured rounds (-jeandle-pea-iterations).
  if (jeandle::isPEAEnabled()) {
    // ---- Pre-PEA high-tier cluster ----
    // Fold jeandle.arraylength(new_array(...)) to the new_array length
    // argument first: the frontend emits jeandle.arraylength both for the
    // arraylength bytecode and for every bounds check, and it is the only
    // pre-lowering reader of the array length field. The folded (possibly
    // constant) length feeds the loop transforms below. Then canonicalize
    // and fully unroll short constant-trip-count loops so PEA sees
    // straight-line, constant-offset array element accesses (Graal runs
    // LoopFullUnroll/LoopPeel/LoopUnswitch before PEA for the same reason;
    // partial/runtime unrolling deliberately stays in the O3 pipeline
    // after PEA — it bloats the analysed loop body without giving PEA any
    // new precision).
    FunctionPassManager PrePEAHighTier;
    PrePEAHighTier.addPass(JavaOpLengthFolding());
    // Re-establish the canonical loop form; the inline driver may have
    // introduced loops that are not in simplified form.
    PrePEAHighTier.addPass(LoopSimplifyPass());
    {
      // Loop-canonicalization pipeline: rotation makes loops do-while
      // shaped, indvars rewrites induction variables into a form SCEV can
      // compute trip counts for, deletion removes side-effect-free loops.
      LoopPassManager CanonicalizeLPM;
      CanonicalizeLPM.addPass(LoopRotatePass());
      CanonicalizeLPM.addPass(IndVarSimplifyPass());
      CanonicalizeLPM.addPass(LoopDeletionPass());
      PrePEAHighTier.addPass(
          createFunctionToLoopPassAdaptor(std::move(CanonicalizeLPM)));
    }
    // Aggressive full-unroll-only: OptLevel=3 raises the cost threshold to
    // unroll-threshold-aggressive (300, boostable to 400%). Partial,
    // runtime, and upper-bound unrolling are disabled; peeling stays at the
    // default policy (it peels a few iterations off loops that resist full
    // unrolling, exposing straight-line allocations to PEA).
    PrePEAHighTier.addPass(LoopUnrollPass(
        LoopUnrollOptions(/*OptLevel=*/3)
            .setPartial(false)
            .setRuntime(false)
            .setUpperBound(false)
            .setFullUnrollMaxCount(JeandlePrePEAFullUnrollMaxCount)));
    PrePEAHighTier.addPass(createFunctionToLoopPassAdaptor(
        SimpleLoopUnswitchPass(/*NonTrivial=*/true)));
    PrePEAHighTier.addPass(InstCombinePass());
    PrePEAHighTier.addPass(GVNPass());
    PrePEAHighTier.addPass(SimplifyCFGPass());
    PM.addPass(createModuleToFunctionPassAdaptor(std::move(PrePEAHighTier)));
    // Pre-PEA cleanup. PEA's correctness depends on the CFG containing no
    // statically-unreachable edges: a constant-condition branch's dead arm
    // would otherwise feed merges and PHIs with no-op contributions and (for
    // edges into blocks with side-effecting calls) cause spurious
    // materialisations of virtuals on paths that never execute. We delegate
    // this to upstream LLVM: SimplifyCFG folds constant-cond branches and
    // deletes blocks unreachable from entry (via removeUnreachableBlocks);
    // ADCE drops the now-dead instructions that fed the folded conditions;
    // InstCombine exposes any further foldable conditions for the next
    // iteration. LoopSimplify runs after SimplifyCFG so it restores the
    // unique-preheader / single-backedge canonical form that SimplifyCFG
    // may have dismantled — processLoop relies on it for every natural
    // loop, and falls back gracefully for irreducible or indirectbr-entered
    // loops that LoopSimplify cannot recover. This mirrors the
    // inter-iteration canonicalisation that PartialEscapeIterative runs
    // between rounds.
    PM.addPass(createModuleToFunctionPassAdaptor(ADCEPass()));
    PM.addPass(createModuleToFunctionPassAdaptor(SimplifyCFGPass()));
    PM.addPass(createModuleToFunctionPassAdaptor(LoopSimplifyPass()));
    PM.addPass(createModuleToFunctionPassAdaptor(InstCombinePass()));
    // Outer fixpoint. PartialEscapeIterative wraps the
    // analyze+transform pair in a bounded loop with InstCombine/SimplifyCFG/
    // ADCE between rounds. The iteration cap is controlled by
    // `-jeandle-pea-iterations=N` (default 2).
    //
    // Pipeline position decision.
    //   Jeandle runs PEA at exactly ONE position. JavaOperationLower(0) is
    //   hoisted above the inline driver (so phase-0 helpers like
    //   instanceof/idiv are inlined before inlining runs); PEA runs after the
    //   driver and the pre-PEA cleanup, before InstSimplify,
    //   TypeCheckElimination, and the standard O2 pipeline. Ops that PEA can
    //   fold — allocations, monitors, and helpers whose expanded body would
    //   expose a raw header/klass load that kills virtualization
    //   (load_klass / arraylength / array_store_check / check_if_value_based)
    //   — carry `"lower-phase"="1"` and are left untouched by
    //   JavaOperationLower(0) (phase-0 only) and by every pass downstream of
    //   PEA, surviving until JavaOperationLower(1) below. addrspace(1)
    //   survives until RewriteStatepointsForGC rewrites it to gc-managed
    //   pointers.
    //
    //   Considered and rejected: a second `PartialEscapeIterative` after the
    //   O2 pipeline. The named intrinsics and addrspace(1) survive through
    //   O2 + GC barriers, so it would be technically feasible. However:
    //     - Phase-0 helpers (instanceof / div/rem) do not allocate or escape;
    //       inlining them via JavaOperationLower(0) cannot expose new
    //       allocation-virtualization opportunities for a second PEA round to
    //       capture.
    //     - O2's stock passes (InstCombine, SimplifyCFG, GVN, SROA, LICM,
    //       loop unroll) cannot SROA or fold addrspace(1) loads — they have
    //       no Java semantic model for the heap — so they neither destroy
    //       PEA invariants nor expose meaningful new escape decisions.
    //     - Intra-PEA fixpoint already iterates through any re-foldable
    //       materializations exposed by InstCombine+SimplifyCFG+ADCE between
    //       rounds.
    PM.addPass(createModuleToFunctionPassAdaptor(PartialEscapeIterative()));
  }
  // Post-inline type recovery + TCE — unconditional. Runs for both PEA-on
  // (cleans up PEA's materializations) and PEA-off (the default config) so
  // RecoverTypeInfo re-attaches !java-klass metadata stripped by the inline
  // driver's load CSE (EarlyCSE/InstCombine) before each TypeCheckElimination
  // round and TCE sees the recovered declared field types.
  PM.addPass(createModuleToFunctionPassAdaptor(InstSimplifyPass()));
  PM.addPass(createModuleToFunctionPassAdaptor(RecoverTypeInfo()));
  PM.addPass(createModuleToFunctionPassAdaptor(TypeCheckElimination()));
  PM.addPass(createModuleToFunctionPassAdaptor(RepeatedConstantFolding()));
  PM.addPass(createModuleToFunctionPassAdaptor(ArrayCopySpecialization()));
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
