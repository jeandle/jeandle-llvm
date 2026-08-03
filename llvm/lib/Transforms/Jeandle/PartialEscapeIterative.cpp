//===- PartialEscapeIterative.cpp - PEA outer fixpoint --------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
// Outer fixpoint. Re-runs PartialEscapeAnalysis + PartialEscapeTransform,
// running the standard canonicalization passes (ADCE + SimplifyCFG +
// LoopSimplify + InstCombine) in every round, until the transform and
// canonicalized IR both reach a bounded fixpoint.
// Each MaterializeEffect reuses the allocation call at its original site and
// emits field/lock replay along the paths that require a materialized value; it
// never creates or relocates an allocation. PEA can delete fully non-escaping
// allocations. A deopt-bundle rewrite may replace an allocation call in place,
// without adding an allocation or changing its site.
//
// Convergence (see `run()`): a round is a fixpoint only when the PEA transform
// is idle and the complete current canonicalization sequence leaves the exact
// printed Function IR unchanged. The round cap is configured by
// `-jeandle-pea-iterations` (hard-capped at HardIterationCap). Each round
// explicitly abandons PartialEscapeAnalysis before invalidation, so no
// PEAResult crosses rounds.
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/PartialEscapeIterative.h"

#include "llvm/Analysis/Jeandle/PartialEscapeAnalysis.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/PassManager.h"
#include "llvm/IR/Verifier.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/InstCombine/InstCombine.h"
#include "llvm/Transforms/Jeandle/PartialEscapeTransform.h"
#include "llvm/Transforms/Scalar/ADCE.h"
#include "llvm/Transforms/Scalar/SimplifyCFG.h"
#include "llvm/Transforms/Utils/LoopSimplify.h"

#include <string>

#define DEBUG_TYPE "jeandle-pea-iterative"

using namespace llvm;

// Default 2 rounds, matching Graal. A nested virtual-reference merge can use
// both productive rounds: the first materializes predecessor effects and the
// second re-analyzes the resulting explicit Phi for Case C. A later idle round
// is only a convergence probe; it is not required to complete that rewrite.
// The hard cap is HardIterationCap (16).
static cl::opt<unsigned> JeandlePEAIterations(
    "jeandle-pea-iterations", cl::init(2), cl::Hidden,
    cl::desc("PEA: maximum number of analyze+transform+canonicalize rounds "
             "in the outer fixpoint. Default 2. Set to 1 for single-round "
             "semantics or higher to observe an idle convergence probe."));

// PEA-only IR dump hook. When non-empty and matching F.getName(), dumps F to
// errs() before and after each complete outer round, followed by a summary.
// Filter with `2>&1 | grep PEA-` to isolate PEA diagnostics.
static cl::opt<std::string> JeandleDumpPEAIR(
    "jeandle-dump-pea-ir", cl::init(""), cl::Hidden,
    cl::desc("PEA: dump function IR to errs() before AND after every outer "
             "round whose function name contains the given substring. Empty "
             "(the default) disables the dump."));

static cl::list<std::string> JeandleDumpPEAIRFunctions(
    "jeandle-dump-pea-ir-function", cl::Hidden,
    cl::desc("PEA: restrict IR dumps to functions whose name exactly matches "
             "one of the supplied names. May be repeated. Empty (the "
             "default) preserves substring-filter behavior."),
    cl::value_desc("function"));

static bool matchesExactDumpFunction(StringRef FunctionName) {
  if (JeandleDumpPEAIRFunctions.empty())
    return true;
  for (const std::string &Allowed : JeandleDumpPEAIRFunctions)
    if (FunctionName == StringRef(Allowed))
      return true;
  return false;
}

// Hard upper bound guarding against non-converging inputs.
static constexpr unsigned HardIterationCap = 16;

bool llvm::jeandle::isPEAEnabled(bool EnableByPipeline) {
  return EnableByPipeline && JeandlePEAIterations != 0;
}

static std::string printFunctionIR(const Function &F) {
  std::string IR;
  raw_string_ostream OS(IR);
  F.print(OS);
  return IR;
}

PreservedAnalyses PartialEscapeIterative::run(Function &F,
                                              FunctionAnalysisManager &FAM) {
  // Gate on jeandle.java_method_compilation. Mirrors the gating in
  // PartialEscapeAnalysis::run and PartialEscapeTransform::run so non-Java
  // functions skip the loop entirely.
  Module *M = F.getParent();
  if (!M || !M->getNamedMetadata(jeandle::Metadata::JavaMethodCompilation))
    return PreservedAnalyses::all();

  const unsigned Requested = JeandlePEAIterations;
  if (Requested == 0)
    return PreservedAnalyses::all();
  const unsigned IterCap = std::min(Requested, HardIterationCap);

  bool AnyChanged = false;

  // Run a sub-pass directly and invalidate FAM with its PreservedAnalyses,
  // mirroring what FunctionPassManager does between adjacent passes so the
  // cached analyses (DominatorTree, LoopInfo, ...) stay fresh for the next.
  auto runAndInvalidate = [&](auto &&Pass) -> PreservedAnalyses {
    PreservedAnalyses Sub = Pass.run(F, FAM);
    FAM.invalidate(F, Sub);
    return Sub;
  };

  // Dump-IR gating (legacy substring and exact allowlist matches are fixed
  // for the run).
  const bool HasDumpFilter =
      !JeandleDumpPEAIR.empty() || !JeandleDumpPEAIRFunctions.empty();
  const bool LegacyDumpMatches =
      JeandleDumpPEAIR.empty() || F.getName().contains(JeandleDumpPEAIR);
  const bool DumpThisFunc = HasDumpFilter && LegacyDumpMatches &&
                            matchesExactDumpFunction(F.getName());
  unsigned ExecutedRounds = 0;
  bool ReachedFixpoint = false;

  for (unsigned Iter = 0; Iter < IterCap; ++Iter) {
    if (DumpThisFunc) {
      errs() << ";; PEA-DUMP before iter=" << Iter << " function "
             << F.getName() << "\n"
             << F << "\n";
    }
    // The transform triggers PartialEscapeAnalysis via FAM.getResult, which
    // constructs a fresh PEAResult for this round.
    PartialEscapeTransform Transform;
    // Run by hand so this round's transform result can explicitly abandon its
    // cached PEAResult before the canonicalization sequence.
    PreservedAnalyses TransformPA = Transform.run(F, FAM);
    const bool TransformIdle = TransformPA.areAllPreserved();
    // Each outer round requires a fresh PEAResult, including after an
    // idempotent transform. Other function analyses remain governed by the
    // transform's preservation result and the canonicalization passes below.
    TransformPA.abandon<PartialEscapeAnalysis>();
    FAM.invalidate(F, TransformPA);
    AnyChanged |= !TransformIdle;
    ExecutedRounds = Iter + 1;

    // Canonicalization is part of every executed round, including the last
    // round allowed by the cap. Order: ADCE → SimplifyCFG → LoopSimplify →
    // InstCombine. Compare the complete sequence's deterministic printed IR;
    // individual passes may conservatively invalidate analyses, and adjacent
    // passes may make offsetting structural changes.
    const std::string BeforeCanonicalization = printFunctionIR(F);
    ADCEPass Dc;
    SimplifyCFGPass Sc;
    LoopSimplifyPass Ls;
    InstCombinePass Ic;
    // A pass returning PreservedAnalyses::all() guarantees it made no IR
    // change. When every canonicalization pass does, the IR is unchanged so the
    // after-print is skipped via short-circuit; otherwise fall back to the
    // exact printed-IR compare. PreservedAnalyses is only a sound "unchanged"
    // signal here — a non-all result can still leave the IR bit-identical.
    bool AnyCanonMutated = false;
    AnyCanonMutated |= !runAndInvalidate(Dc).areAllPreserved();
    AnyCanonMutated |= !runAndInvalidate(Sc).areAllPreserved();
    AnyCanonMutated |= !runAndInvalidate(Ls).areAllPreserved();
    AnyCanonMutated |= !runAndInvalidate(Ic).areAllPreserved();
    const bool CanonChanged =
        AnyCanonMutated && BeforeCanonicalization != printFunctionIR(F);
    AnyChanged |= CanonChanged;

    if (DumpThisFunc) {
      errs() << ";; PEA-DUMP after iter=" << Iter << " function " << F.getName()
             << " transform_idle=" << TransformIdle << "\n"
             << F << "\n";
    }

    // Validate the complete round boundary so the after dump and the next
    // round always observe the same well-formed IR.
#ifndef NDEBUG
    if ((!TransformIdle || CanonChanged) && verifyFunction(F, &errs())) {
      errs() << "PEA: produced malformed IR for " << F.getName()
             << " at iter=" << Iter << "\n";
      llvm_unreachable("PartialEscapeIterative produced malformed IR");
    }
#endif

    LLVM_DEBUG({
      dbgs() << "PartialEscapeIterative[" << F.getName() << "] iter=" << Iter
             << " transform_idle=" << TransformIdle
             << " canon_changed=" << CanonChanged << "\n";
    });

    if (TransformIdle && !CanonChanged) {
      ReachedFixpoint = true;
      break;
    }
  }

  if (DumpThisFunc)
    errs() << ";; PEA-SUMMARY function " << F.getName()
           << " rounds=" << ExecutedRounds
           << " stop=" << (ReachedFixpoint ? "fixpoint" : "iteration-cap")
           << "\n";

  return AnyChanged ? PreservedAnalyses::none() : PreservedAnalyses::all();
}
