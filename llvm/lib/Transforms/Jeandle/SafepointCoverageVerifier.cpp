//===- SafepointCoverageVerifier.cpp - Safepoint Coverage Check -----------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
///
/// Verifies that every natural loop either reaches a safepoint on every
/// backedge path or has a SCEV-provable finite bound accepted by the poll
/// elimination policy. Strip-mined inner loops are accepted via the
/// "jeandle.strip-mined-poll" attribute on the poll relocated onto the outer
/// back-edge: this verifier is adjacent to SafepointStripMining in the
/// pipeline, so the marker is always fresh and trusted.
///
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/SafepointCoverageVerifier.h"
#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/CFG.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/ScalarEvolution.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/JeandleUtils.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/Jeandle/SafepointUtils.h"

using namespace llvm;

#define DEBUG_TYPE "safepoint-coverage-verifier"

using jeandle::SafepointCoverageCheck;

namespace {

static bool blockHasSafepoint(BasicBlock *BB) {
  return llvm::any_of(*BB, jeandle::isSafepoint);
}

// Walking backwards from a latch and cutting the search at every safepoint
// proves coverage by disjoint branch arms as well as single-block dominance.
// Reaching the header without crossing a safepoint exposes an uncovered
// backedge path.
static bool allPathsToLatchReachSafepoint(Loop &L, BasicBlock *Latch) {
  SmallVector<BasicBlock *, 8> Worklist{Latch};
  SmallPtrSet<BasicBlock *, 16> Visited;
  while (!Worklist.empty()) {
    BasicBlock *BB = Worklist.pop_back_val();
    if (!Visited.insert(BB).second || blockHasSafepoint(BB))
      continue;
    if (BB == L.getHeader())
      return false;

    bool HasLoopPredecessor = false;
    for (BasicBlock *Pred : predecessors(BB)) {
      if (!L.contains(Pred))
        return false;
      HasLoopPredecessor = true;
      Worklist.push_back(Pred);
    }
    if (!HasLoopPredecessor)
      return false;
  }
  return true;
}

static cl::opt<SafepointCoverageCheck> CoverageCheck(
    "jeandle-verify-safepoint-coverage",
    cl::values(clEnumValN(SafepointCoverageCheck::Off, "off",
                          "Do not run the safepoint coverage verifier"),
               clEnumValN(SafepointCoverageCheck::Warn, "warn",
                          "Report all coverage violations without aborting"),
               clEnumValN(SafepointCoverageCheck::Fatal, "fatal",
                          "Abort the compile on any coverage violation")),
#ifndef NDEBUG
    cl::init(SafepointCoverageCheck::Fatal),
#else
    cl::init(SafepointCoverageCheck::Off),
#endif
    cl::desc("Safepoint coverage verifier mode."));

static bool isLoopCovered(Loop &L, ScalarEvolution &SE) {
  SmallVector<BasicBlock *, 4> Latches;
  L.getLoopLatches(Latches);
  if (Latches.empty())
    return false;

  if (Latches.size() == 1 && jeandle::isMarkedStripMinedInner(L))
    return true;

  bool AllLatchesCovered = llvm::all_of(Latches, [&](BasicBlock *Latch) {
    return allPathsToLatchReachSafepoint(L, Latch);
  });
  if (AllLatchesCovered)
    return true;

  jeandle::LoopSafepointFacts Facts = jeandle::LoopSafepointFacts::get(L, SE);
  if (!jeandle::isMarkedStripMinedInner(L) &&
      !jeandle::isStripMiningEnabled() && Facts.IsIntCountedEquivalent)
    return true;

  return Facts.IsWithinBudget;
}

} // namespace

SafepointCoverageCheck llvm::jeandle::getSafepointCoverageCheck() {
  return CoverageCheck;
}

PreservedAnalyses SafepointCoverageVerifier::run(Function &F,
                                                 FunctionAnalysisManager &AM) {
  // The verifier is a backstop for normal Java-method compilations. A module
  // carrying the skip-safepoint-coverage-verifier named metadata opts out — this
  // is set only for compilation paths with different safepoint semantics (e.g.
  // intrinsic lowering / runtime stubs), not for every Java method.
  if (F.getParent()->getNamedMetadata(
          jeandle::Metadata::SkipSafepointCoverageVerifier))
    return PreservedAnalyses::all();

  if (CoverageCheck == SafepointCoverageCheck::Off ||
      !jeandle::isRootJavaMethodFunction(F))
    return PreservedAnalyses::all();

  auto &LI = AM.getResult<LoopAnalysis>(F);
  ReversePostOrderTraversal<const Function *> RPOT(&F);
  if (containsIrreducibleCFG<const BasicBlock *>(RPOT, LI)) {
    LLVM_DEBUG(dbgs() << "  coverage not verified for irreducible function "
                      << F.getName() << "\n");
    return PreservedAnalyses::all();
  }

  auto &SE = AM.getResult<ScalarEvolutionAnalysis>(F);

  bool Broken = false;
  for (Loop *L : LI.getLoopsInPreorder()) {
    if (isLoopCovered(*L, SE)) {
      LLVM_DEBUG(dbgs() << "  covered: loop " << L->getHeader()->getName()
                        << " in " << F.getName() << "\n");
      continue;
    }
    Broken = true;
    errs() << "SafepointCoverageVerifier: loop with header '"
           << L->getHeader()->getName() << "' in function '" << F.getName()
           << "' has an uncovered backedge path and no provable trip bound\n";
  }

  if (Broken && CoverageCheck == SafepointCoverageCheck::Fatal)
    report_fatal_error("Jeandle safepoint coverage verification failed");
  return PreservedAnalyses::all();
}
