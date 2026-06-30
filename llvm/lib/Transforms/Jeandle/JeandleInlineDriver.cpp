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
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Jeandle/VMCallback.h"
#include "llvm/IR/Jeandle/VMCallbackLog.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/PassManager.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/Jeandle/JeandleDevirtualization.h"
#include "llvm/Transforms/Scalar/InstSimplifyPass.h"

#include <string>
#include <utility>

#define DEBUG_TYPE "jeandle-inline-driver"

using namespace llvm;

static bool isJeandleJavaMethod(const Function &F) {
  return F.hasFnAttribute(jeandle::Attribute::JavaMethod);
}

static bool isRootJavaMethodFunction(const Function &F) {
  return isJeandleJavaMethod(F) && !F.isDeclaration() &&
         !F.hasAvailableExternallyLinkage();
}

static Function *getRootJavaMethodFunction(Module &M) {
  Function *RootFunction = nullptr;
  for (Function &F : M) {
    if (!isRootJavaMethodFunction(F))
      continue;
    if (!RootFunction) {
      RootFunction = &F;
    } else {
      std::string Message;
      raw_string_ostream OS(Message);
      OS << "JeandleInliner: expected at most one root Java method function, "
         << "found '" << RootFunction->getName() << "' and '" << F.getName()
         << "'";
      OS.flush();
      report_fatal_error(StringRef(Message));
    }
  }
  return RootFunction;
}

static void eraseInlineScopeIDs(Function &RootFunction) {
  // inline-scope-id is private scheduling metadata produced and consumed only
  // by this driver. Removing it before returning does not change the program IR
  // seen by later passes, so it is intentionally not reported through
  // PreservedAnalyses.
  for (Instruction &I : instructions(RootFunction)) {
    auto *CB = dyn_cast<CallBase>(&I);
    if (!CB || !CB->getMetadata(jeandle::Metadata::InlineScopeID))
      continue;
    CB->setMetadata(jeandle::Metadata::InlineScopeID, nullptr);
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
  Function *RootFunction = getRootJavaMethodFunction(M);
  if (!RootFunction)
    return PreservedAnalyses::all();

  FunctionAnalysisManager &FAM =
      MAM.getResult<FunctionAnalysisManagerModuleProxy>(M).getManager();

  PreservedAnalyses FunctionPA = InstSimplifyPass().run(*RootFunction, FAM);
  if (FunctionPA.areAllPreserved())
    return PreservedAnalyses::all();

  FAM.invalidate(*RootFunction, FunctionPA);

  PreservedAnalyses PA;
  // InstSimplify only runs on the root function here. Its function analyses
  // have already been invalidated with the pass result above, so keep the FAM
  // proxy and unrelated function-analysis caches alive for the module manager.
  PA.preserve<FunctionAnalysisManagerModuleProxy>();
  PA.preserveSet<AllAnalysesOn<Function>>();
  return PA;
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
  JeandleDevirtualization Devirtualization;
  SmallVector<JeandleInlineScope, 16> InlineScopes;
  PreservedAnalyses DriverPA = PreservedAnalyses::all();
  bool Changed = false;

  // The driver owns the inline/devirtualization loop. Keeping InlineScopes here
  // lets future devirtualization steps preserve JVM callback scope IDs across
  // IR rewrites instead of trying to infer scope from a freshly scanned root
  // body.
  //
  // Loop shape:
  //   1. Run one inline round. The round tags every newly exposed call site
  //      with inline-scope-id metadata.
  //   2. If the inline round did not expose any new call sites, stop.
  //   3. Run devirtualization refinement. It must propagate inline-scope-id
  //      and deopt/BCI information when it clones or replaces calls.
  //   4. If devirtualization preserved everything, it did not produce a new
  //      MonomorphicTarget call site and the loop stops; otherwise rescan IR
  //      in the next inline round.
  bool HitIterationLimit = true;
  for (unsigned Iteration = 0; Iteration < MaxInlineDriverIterations;
       ++Iteration) {
    InlineRoundResult InlineResult =
        Inliner.runInlineRound(M, MAM, InlineScopes);
    Changed |= !InlineResult.PA.areAllPreserved();
    updateDriverPreservedAnalyses(M, MAM, DriverPA, std::move(InlineResult.PA));

    if (!InlineResult.ExposedNewCallSites) {
      HitIterationLimit = false;
      break;
    }

    // Keep the per-round cleanup conservative: InstSimplify performs local
    // instruction simplification without introducing new instructions or
    // rewriting the CFG. Run it before devirtualization so newly exposed call
    // sites are seen after cheap local folding.
    PreservedAnalyses SimplifyPA = runRootInstSimplify(M, MAM);
    Changed |= !SimplifyPA.areAllPreserved();
    updateDriverPreservedAnalyses(M, MAM, DriverPA, std::move(SimplifyPA));

    PreservedAnalyses DevirtPA = Devirtualization.runDevirtualization(M, MAM);
    bool AddedMonomorphicTargets = !DevirtPA.areAllPreserved();
    Changed |= AddedMonomorphicTargets;
    updateDriverPreservedAnalyses(M, MAM, DriverPA, std::move(DevirtPA));

    // Devirtualization may rewrite the root IR and replace CallBase objects
    // exposed by the inline round. Do not carry a cross-step worklist through
    // this point; the next inline round rescans the root function and should
    // read the preserved inline-scope-id metadata from surviving/generated call
    // sites.
    if (!AddedMonomorphicTargets) {
      HitIterationLimit = false;
      break;
    }
  }

  if (HitIterationLimit) {
    LLVM_DEBUG(dbgs() << "JeandleInlineDriver: inline loop reached "
                      << MaxInlineDriverIterations
                      << " iterations; this indicates an abnormal long inline "
                         "loop, stopping inline early. Please investigate the "
                         "inline/devirtualization convergence.\n");
  }

  if (!Changed)
    return PreservedAnalyses::all();

  Function *RootFunction = getRootJavaMethodFunction(M);
  FunctionAnalysisManager &FAM =
      MAM.getResult<FunctionAnalysisManagerModuleProxy>(M).getManager();

  // inline-scope-id is driver-local scheduling state. It is only needed while
  // the driver loop is active so devirtualization rewrites can preserve scope
  // IDs for the next inline round. Drop it before leaving the driver to avoid
  // leaking stale scope IDs into later optimizations or a future driver
  // invocation.
  if (RootFunction)
    eraseInlineScopeIDs(*RootFunction);

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
