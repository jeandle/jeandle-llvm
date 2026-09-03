//===- JeandleInlineDriver.cpp - Jeandle inline driver --------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file implements the Jeandle inline driver. The driver is a
// pass-manager-like wrapper around single-round inlining and future
// devirtualization refinement. It follows the same shape as
// DevirtSCCRepeatedPass: run one step, invalidate analyses for that step,
// intersect the preserved analyses, and iterate while the driver-specific
// progress condition holds.
//
// This is intentionally not a plain ModulePassManager. The driver must consume
// step-specific inline results, such as ExposedNewCallSites, to decide when the
// repeat loop has reached a fixed point. Standard pass managers only propagate
// PreservedAnalyses, so the repeat policy has to live in this wrapper.
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/JeandleInliner.h"

#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/Attributes.h"
#include "llvm/IR/Jeandle/JeandleUtils.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Jeandle/VMCallbackLog.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/PassManager.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/InstCombine/InstCombine.h"
#include "llvm/Transforms/Jeandle/CHADevirtualization.h"
#include "llvm/Transforms/Jeandle/JavaOperationLower.h"
#include "llvm/Transforms/Jeandle/ProfileDevirtualization.h"
#include "llvm/Transforms/Jeandle/RecoverTypeInfo.h"
#include "llvm/Transforms/Jeandle/RepeatedConstantFolding.h"
#include "llvm/Transforms/Jeandle/TypeCheckElimination.h"
#include "llvm/Transforms/Scalar/ADCE.h"
#include "llvm/Transforms/Scalar/EarlyCSE.h"
#include "llvm/Transforms/Scalar/InstSimplifyPass.h"
#include "llvm/Transforms/Scalar/SimplifyCFG.h"

#include <utility>

#define DEBUG_TYPE "jeandle-inline-driver"

using namespace llvm;

using llvm::jeandle::getRootJavaMethodFunction;
using llvm::jeandle::isJeandleJavaMethod;
using llvm::jeandle::isRootJavaMethodFunction;

static void eraseInlineSchedulingMetadata(Function &RootFunction) {
  // inline-scope-id is private scheduling metadata produced and consumed only
  // by this driver. Removing it before returning does not change the program IR
  // seen by later passes, so it is intentionally not reported through
  // PreservedAnalyses.
  for (Instruction &I : instructions(RootFunction)) {
    auto *CB = dyn_cast<CallBase>(&I);
    if (!CB)
      continue;
    CB->setMetadata(jeandle::Metadata::InlineScopeID, nullptr);
    CB->setMetadata(jeandle::Metadata::LateInline, nullptr);
  }
}

static bool eraseAvailableExternallyJavaMethods(Module &M,
                                                Function *RootFunction,
                                                FunctionAnalysisManager &FAM) {
  SmallVector<Function *, 16> Candidates;
  bool Changed = false;

  for (Function &F : M) {
    if (&F == RootFunction || !isJeandleJavaMethod(F) ||
        !F.hasAvailableExternallyLinkage())
      continue;
    Candidates.push_back(&F);
  }

  for (Function *F : Candidates) {
    if (F->isDeclaration())
      continue;
    FAM.clear(*F, F->getName());
    F->deleteBody();
    Changed = true;
  }

  for (Function *F : Candidates) {
    if (!F->use_empty())
      continue;
    FAM.clear(*F, F->getName());
    F->eraseFromParent();
    Changed = true;
  }

  return Changed;
}

static void updateDriverPreservedAnalyses(Module &M, ModuleAnalysisManager &MAM,
                                          PreservedAnalyses &DriverPA,
                                          PreservedAnalyses StepPA) {
  MAM.invalidate(M, StepPA);
  DriverPA.intersect(std::move(StepPA));
}

// Normal termination is controlled by VM inline policy, such as max inline
// level, plus whether devirtualization exposes new monomorphic call sites.
// Keep a large hard cap here only as a last-resort guard against future
// refinement passes accidentally creating a non-converging driver loop. It is
// not a normal compile-time or inline-aggressiveness tuning knob; those should
// stay in the VM policy layer.
static constexpr unsigned MaxInlineDriverIterations = 512;

static PreservedAnalyses runRootInstSimplify(Module &M,
                                             ModuleAnalysisManager &MAM) {
  bool Changed = false;
  Function *RootFunction = getRootJavaMethodFunction(M);
  if (!RootFunction) {
    return PreservedAnalyses::all();
  }

  FunctionAnalysisManager &FAM =
      MAM.getResult<FunctionAnalysisManagerModuleProxy>(M).getManager();

  // Per-round root cleanup, mirroring the O3 "simplify after inline" cleanup.
  //   - InstSimplify: cheap local instruction folding, no CFG rewrite.
  //   - RecoverTypeInfo: re-attach !java-klass metadata that the previous
  //     round's EarlyCSE/InstCombine load CSE stripped, so this round's
  //     TypeCheckElimination still sees declared field types.
  //   - TypeCheckElimination: fold jeandle.check_instanceof to constants,
  //     exposing monomorphic call sites for the next devirtualization round.
  //   - RepeatedConstantFolding: fold constant fields to a fixed point,
  //     pruning newly dead paths between iterations.
  //   - EarlyCSE: common-subexpression elimination (also load CSE), removes
  //     redundant computation.
  //   - InstCombine: instruction simplification + constant folding/
  //     propagation, and removal of dead instructions.
  //   - SimplifyCFG: remove unreachable blocks, merge blocks, fold branches.
  //   - ADCE: aggressive dead-code elimination.
  FunctionPassManager FPM;
  FPM.addPass(InstSimplifyPass());
  FPM.addPass(RecoverTypeInfo());
  FPM.addPass(TypeCheckElimination());
  FPM.addPass(RepeatedConstantFolding());
  FPM.addPass(EarlyCSEPass());
  FPM.addPass(InstCombinePass());
  FPM.addPass(SimplifyCFGPass());
  FPM.addPass(ADCEPass());
  FPM.addPass(RecoverTypeInfo()); // Recover type information in the end.

  PreservedAnalyses RootPA = FPM.run(*RootFunction, FAM);
  Changed |= !RootPA.areAllPreserved();

  if (!Changed)
    return PreservedAnalyses::all();

  RootPA.preserve<FunctionAnalysisManagerModuleProxy>();
  return RootPA;
}

static PreservedAnalyses runPreLateInlinePasses(Module &,
                                                ModuleAnalysisManager &) {
  // Java-specific elimination passes that need to see calls before late
  // inlining should be added here. Keep this hook separate from the normal
  // refinement loop so those passes run only immediately before a late round.
  return PreservedAnalyses::all();
}

PreservedAnalyses JeandleInlineDriver::run(Module &M,
                                           ModuleAnalysisManager &MAM) {
  jeandle::registerInlineCalleeIRReplayMaterializer(
      &jeandle::detail::materializeInlineCalleeIRForReplay);
  // ReplayM is parsed into M's LLVMContext, so context-uniqued constants may
  // share use-lists with M. Keep the replay state scoped to this driver run so
  // later passes cannot leave cross-module uses in thread-local replay state.
  struct InlineCalleeReplayScope {
    explicit InlineCalleeReplayScope(Module &M) : ReplayModuleScope(M) {}
    ~InlineCalleeReplayScope() {
      jeandle::detail::clearInlineCalleeReplayState();
    }

    jeandle::VMCallbackReplayModuleScope ReplayModuleScope;
  } ReplayScope(M);

  JeandleInliner Inliner(InlineAccessorsOnly);
  CHADevirtualization Devirtualization;
  ProfileDevirtualization ProfileDevirt;
  SmallVector<JeandleInlineScope, 16> InlineScopes;
  PreservedAnalyses DriverPA = PreservedAnalyses::all();
  Function *RootFunction = getRootJavaMethodFunction(M);
  bool Changed = false;

  // The driver owns the inline/devirtualization loop. Keeping InlineScopes here
  // lets future devirtualization steps preserve JVM callback scope IDs across
  // IR rewrites instead of trying to infer scope from a freshly scanned root
  // body.
  //
  // Loop shape:
  //   1. Run one inline round. The round tags every newly exposed call site
  //      with inline-scope-id metadata.
  //   2. A late round first runs Java-specific pre-late passes. Every changed
  //      inline round then lowers newly exposed phase-0 JavaOps and simplifies
  //      the root before refinement.
  //   3. Eager rounds run until ordinary inlining reaches a fixed point. If
  //      delayed candidates remain, the driver then enters the late phase.
  //   4. The phase transition is one-way. Each late round processes markers
  //   that
  //      existed before its pre-late passes, and also handles ordinary calls
  //      exposed by late inlining/refinement. A new InlineLater decision only
  //      sets metadata, so that call cannot run until the next pre-late
  //      boundary.
  //   5. Run devirtualization refinement. It must propagate inline-scope-id
  //      and deopt/BCI information when it clones or replaces calls.
  //   6. Late rounds repeat until neither refinement nor marked calls provide
  //      more work.
  bool HitIterationLimit = true;
  bool InLateInlinePhase = false;
  for (unsigned Iteration = 0; Iteration < MaxInlineDriverIterations;
       ++Iteration) {

    if (InLateInlinePhase) {
      PreservedAnalyses PreLatePA = runPreLateInlinePasses(M, MAM);
      Changed |= !PreLatePA.areAllPreserved();
      updateDriverPreservedAnalyses(M, MAM, DriverPA, std::move(PreLatePA));
    }

    InlineRoundResult InlineResult =
        Inliner.runInlineRound(M, MAM, InlineScopes, InLateInlinePhase);
    bool RoundChanged = !InlineResult.PA.areAllPreserved();
    Changed |= RoundChanged;

    if (RoundChanged) {
      updateDriverPreservedAnalyses(M, MAM, DriverPA,
                                    std::move(InlineResult.PA));

      // Lower phase-0 JavaOp call sites exposed by this inline round.
      PreservedAnalyses JavaOpLowerPA = JavaOperationLower(0).run(M, MAM);
      Changed |= !JavaOpLowerPA.areAllPreserved();
      updateDriverPreservedAnalyses(M, MAM, DriverPA, std::move(JavaOpLowerPA));

      // Per-round cleanup.
      PreservedAnalyses CleanupPA = runRootInstSimplify(M, MAM);
      Changed |= !CleanupPA.areAllPreserved();
      updateDriverPreservedAnalyses(M, MAM, DriverPA, std::move(CleanupPA));
    }

    if (!InlineResult.ExposedNewCallSites) {
      if (InlineResult.HasLateInlineCandidates) {
        // This assignment is intentionally monotonic. Once eager inlining has
        // stopped making progress, the driver stays in the late scheduling
        // phase. Each call's marker still decides whether its VM query uses
        // the late policy.
        InLateInlinePhase = true;
        continue;
      } else {
        HitIterationLimit = false;
        break;
      }
    }

    FunctionAnalysisManager &FAM =
        MAM.getResult<FunctionAnalysisManagerModuleProxy>(M).getManager();
    PreservedAnalyses DevirtPA = Devirtualization.run(*RootFunction, FAM);
    PreservedAnalyses ProfileDevirtPA = ProfileDevirt.run(*RootFunction, FAM);
    bool AddedMonomorphicTargets =
        !DevirtPA.areAllPreserved() || !ProfileDevirtPA.areAllPreserved();
    Changed |= AddedMonomorphicTargets;
    FAM.invalidate(*RootFunction, DevirtPA);
    FAM.invalidate(*RootFunction, ProfileDevirtPA);
    PreservedAnalyses DevirtModulePA = PreservedAnalyses::all();
    DevirtModulePA.intersect(std::move(DevirtPA));
    DevirtModulePA.intersect(std::move(ProfileDevirtPA));
    DevirtModulePA.preserveSet<AllAnalysesOn<Function>>();
    DevirtModulePA.preserve<FunctionAnalysisManagerModuleProxy>();
    updateDriverPreservedAnalyses(M, MAM, DriverPA, std::move(DevirtModulePA));

    if (InlineResult.HitNodeCountCutoff) {
      if (InLateInlinePhase || !InlineResult.HasLateInlineCandidates) {
        HitIterationLimit = false;
        break;
      }

      InLateInlinePhase = true;
      continue;
    }

    if (!AddedMonomorphicTargets) {
      if (!InlineResult.HasLateInlineCandidates) {
        HitIterationLimit = false;
        break;
      }

      // Refinement produced no ordinary eager work, so the delayed candidates
      // are now the only remaining source of progress. This assignment either
      // performs the one-way eager-to-late transition or keeps an existing late
      // phase active; it never returns the driver to eager inlining.
      InLateInlinePhase = true;
    }
  }

  if (HitIterationLimit) {
    LLVM_DEBUG(dbgs() << "JeandleInlineDriver: inline loop reached "
                      << MaxInlineDriverIterations
                      << " iterations; this indicates an abnormal long inline "
                         "loop, stopping inline early. Please investigate the "
                         "inline/devirtualization convergence.\n");
  }

  // inline-scope-id is driver-local scheduling state. It is only needed while
  // the driver loop is active so devirtualization rewrites can preserve scope
  // IDs for the next inline round. Drop it before leaving the driver to avoid
  // leaking stale scope IDs into later optimizations or a future driver
  // invocation.
  if (RootFunction)
    eraseInlineSchedulingMetadata(*RootFunction);

  if (!Changed)
    return PreservedAnalyses::all();

  FunctionAnalysisManager &FAM =
      MAM.getResult<FunctionAnalysisManagerModuleProxy>(M).getManager();

  // Notify the VM before available_externally callee bodies are removed. The
  // JVM uses this point to snapshot a replay side module containing the IR
  // materialized through GetInlineCalleeIR during this inline driver run.
  const jeandle::VMCallbacks *VC = jeandle::getVMCallbacks();
  if (VC && VC->RecordInliningComplete) {
    bool Recorded = VC->RecordInliningComplete();
    assert(Recorded && "RecordInliningComplete must succeed or be handled by "
                       "the JVM before returning");
    (void)Recorded;
  }

  // Callee IR requested from the JVM is available_externally: it is useful for
  // optimization, but should not remain as a definition after the inline driver
  // is done. If such a method still has uses, delete only its body so existing
  // references stay valid as declarations; otherwise erase the function.
  bool RemovedCalleeIR =
      eraseAvailableExternallyJavaMethods(M, RootFunction, FAM);

  if (RemovedCalleeIR) {
    PreservedAnalyses CleanupPA;
    // eraseAvailableExternallyJavaMethods clears FAM entries for every callee
    // it mutates or erases. Preserve the proxy and remaining function analyses
    // so the module manager does not discard unrelated function-analysis
    // caches.
    CleanupPA.preserve<FunctionAnalysisManagerModuleProxy>();
    CleanupPA.preserveSet<AllAnalysesOn<Function>>();
    updateDriverPreservedAnalyses(M, MAM, DriverPA, std::move(CleanupPA));
  }

  // Like PassManagerImpl.h, invalidation for the current module has already
  // been performed after each driver step. Preserve the remaining cached module
  // analyses for the outer pass manager.
  DriverPA.preserveSet<AllAnalysesOn<Module>>();
  return DriverPA;
}
