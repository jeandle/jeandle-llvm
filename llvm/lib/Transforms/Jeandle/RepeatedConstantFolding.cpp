//===- RepeatedConstantFolding.cpp - Iterate CFF with simplification ------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/RepeatedConstantFolding.h"
#include "llvm/ADT/Statistic.h"
#include "llvm/Support/Debug.h"
#include "llvm/Transforms/Jeandle/ConstantFieldFolding.h"
#include "llvm/Transforms/Scalar/SCCP.h"
#include "llvm/Transforms/Scalar/SimplifyCFG.h"

#define DEBUG_TYPE "repeated-constant-field-folding"

using namespace llvm;

STATISTIC(NumWrapperIterations,
          "Number of CFF iterations driven by RepeatedConstantFolding");
STATISTIC(NumWrapperCleanups,
          "Number of SCCP+SimplifyCFG cleanup rounds between CFF iterations");

PreservedAnalyses RepeatedConstantFolding::run(Function &F,
                                               FunctionAnalysisManager &FAM) {
  // Safety cap on outer iterations. CFF itself is already internally
  // iterative (up to 64 rounds), so each call here is heavy; in practice
  // 1-2 wrapper iterations are expected to converge.
  constexpr unsigned MaxIterations = 4;

  // The cleanup sequence we interleave with CFF. SCCP turns conditional
  // branches with proven-constant conditions into unconditional ones, and
  // SimplifyCFG removes the now-unreachable blocks and prunes PHI incomings
  // that pointed at them - that's exactly what lets the next CFF round
  // upgrade a previously-Bottom PHI lattice to Constant{Id}.
  FunctionPassManager Cleanup;
  Cleanup.addPass(SCCPPass());
  Cleanup.addPass(SimplifyCFGPass());

  bool AnyChanged = false;
  for (unsigned Iter = 0; Iter < MaxIterations; ++Iter) {
    ++NumWrapperIterations;
    PreservedAnalyses CFFPA = ConstantFieldFolding().run(F, FAM);
    // CFF returns PreservedAnalyses::all() iff it folded nothing. Use that
    // as the fixed-point signal so we don't need to modify CFF to expose a
    // separate "changed" bit.
    if (CFFPA.areAllPreserved()) {
      LLVM_DEBUG(dbgs() << "RepeatedCFF: converged after " << Iter
                        << " cleanup rounds\n");
      break;
    }
    AnyChanged = true;
    FAM.invalidate(F, CFFPA);

    // Skip the cleanup after the final CFF round - the downstream pipeline
    // (InsertGCBarriers, the standard O-level passes) will simplify anyway.
    if (Iter + 1 == MaxIterations) {
      LLVM_DEBUG(dbgs() << "RepeatedCFF: hit MaxIterations=" << MaxIterations
                        << ", stopping\n");
      break;
    }

    ++NumWrapperCleanups;
    PreservedAnalyses CleanupPA = Cleanup.run(F, FAM);
    FAM.invalidate(F, CleanupPA);
  }

  if (!AnyChanged)
    return PreservedAnalyses::all();
  // SimplifyCFG mutates the CFG; conservatively invalidate everything.
  return PreservedAnalyses::none();
}
