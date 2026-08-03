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
#include "llvm/Analysis/Jeandle/PartialEscapeAnalysis.h"
#include "llvm/IR/PassManager.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Transforms/InstCombine/InstCombine.h"
#include "llvm/Transforms/Jeandle/CHADevirtualization.h"
#include "llvm/Transforms/Jeandle/ConstantFieldFolding.h"
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
#include "llvm/Transforms/Jeandle/TLSPointerRewrite.h"
#include "llvm/Transforms/Jeandle/TypeCheckElimination.h"
#include "llvm/Transforms/Scalar/ADCE.h"
#include "llvm/Transforms/Scalar/EarlyCSE.h"
#include "llvm/Transforms/Scalar/GVN.h"
#include "llvm/Transforms/Scalar/IndVarSimplify.h"
#include "llvm/Transforms/Scalar/InstSimplifyPass.h"
#include "llvm/Transforms/Scalar/LoopDeletion.h"
#include "llvm/Transforms/Scalar/LoopPassManager.h"
#include "llvm/Transforms/Scalar/LoopRotation.h"
#include "llvm/Transforms/Scalar/LoopUnrollPass.h"
#include "llvm/Transforms/Scalar/RewriteStatepointsForGC.h"
#include "llvm/Transforms/Scalar/SimpleLoopUnswitch.h"
#include "llvm/Transforms/Scalar/SimplifyCFG.h"
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

Pipeline::Pipeline(OptimizationLevel level, LLVMContext &Ctx,
                   PipelineOptions Options)
    : SI(Ctx, /*DebugLogging=*/false) {
  SI.registerCallbacks(PIC, &MAM);

  PassBuilder PB(nullptr, PipelineTuningOptions(), std::nullopt, &PIC);

  // Register all the basic analyses with the managers.
  PB.registerModuleAnalyses(MAM);
  PB.registerCGSCCAnalyses(CGAM);
  FAM.registerPass([PartialEscape = Options.PartialEscape] {
    return PartialEscapeAnalysis(PartialEscape);
  });
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
  // ==== PEA segment ====
  // Everything below up to InsertGCBarriers exists to serve PEA: the
  // high-tier loop-optimization cluster that exposes virtualization
  // opportunities, the pre-PEA cleanup that PEA's correctness depends on,
  // PEA itself, and the post-PEA cleanup. The whole segment is gated on PEA
  // being enabled by both the typed pipeline option and the configured rounds.
  if (jeandle::isPEAEnabled(Options.PartialEscape.Enable)) {
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
  PM.addPass(createModuleToFunctionPassAdaptor(TypeCheckElimination()));
  // TODO: InsertGCBarriers currently inserts high-level barrier calls before
  // O3 because it cannot handle O3 generated memory intrinsics and vector
  // instructions. But the uninlined barrier calls can still block useful
  // optimizations.
  PM.addPass(createModuleToFunctionPassAdaptor(InsertGCBarriers()));
  PM.addPass(JavaOperationLower(1));
  PM.addPass(std::move(PB.buildPerModuleDefaultPipeline(level)));
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
