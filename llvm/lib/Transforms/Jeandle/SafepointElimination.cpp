//===- SafepointElimination.cpp - Jeandle Safepoint Elimination
//------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
///
/// This pass detects counted loops and eliminates safepoint poll instructions
///
/// For counted loops, we can safely eliminate safepoint inside the loop body,
/// similar to Hotspot C2's safepoint elimination optimization.
///
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/SafepointElimination.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/Support/Debug.h"

using namespace llvm;

#define DEBUG_TYPE "safepoint-elimination"

namespace {

/// Check if an instruction is a safepoint call
bool isSafepointCall(CallInst *CI) {
  if (!CI)
    return false;

  return CI->getCalledFunction()->getName() == "jeandle.safepoint_poll";
}

/// Information about a counted loop
struct CountedLoopInfo {
  Loop *TheLoop;
  PHINode *InductionVar;
  Value *ExitBound;
  ICmpInst *ExitCond;
};

/// Check if a loop is a counted loop.
/// Returns std::optional<CountedLoopInfo> with loop information if it's a
/// counted loop, or std::nullopt if it's not.
///
/// A counted loop must have:
/// 1. A canonical induction variable
/// 2. An exit condition that compares the IV with a loop-invariant bound
///
std::optional<CountedLoopInfo> checkCountedLoop(Loop *L) {
  LLVM_DEBUG(dbgs() << "Analyzing loop at " << L->getHeader()->getName()
                    << "\n");

  // Check if this loop has any nested loops
  if (!L->getSubLoops().empty()) {
    LLVM_DEBUG(dbgs() << "  Loop has nested sub-loops, skipping\n");
    return std::nullopt;
  }

  // Look for a canonical induction variable
  PHINode *CanonIV = L->getCanonicalInductionVariable();

  if (!CanonIV) {
    LLVM_DEBUG(dbgs() << "  No canonical induction variable found\n");
    return std::nullopt;
  }

  LLVM_DEBUG(dbgs() << "  Found induction variable: " << *CanonIV << "\n");

  // Find the exit condition
  // Look for ICmp that compares the IV with a loop-invariant bound
  ICmpInst *ExitCond = nullptr;
  Value *ExitBound = nullptr;

  // Check the latch block first
  if (BasicBlock *Latch = L->getLoopLatch()) {
    // If we have a single latch, verify it's the only exiting block
    if (BranchInst *BI = dyn_cast<BranchInst>(Latch->getTerminator())) {
      if (BI->isConditional()) {
        Value *Cond = BI->getCondition();
        if (auto *ICmp = dyn_cast<ICmpInst>(Cond)) {
          Value *Op0 = ICmp->getOperand(0);
          Value *Op1 = ICmp->getOperand(1);

          if (Op0 == CanonIV || Op1 == CanonIV) {
            ExitCond = ICmp;
            ExitBound = (Op0 == CanonIV) ? Op1 : Op0;
          }
        }
      }
    }
  }

  // If not found in latch, search exiting blocks
  if (!ExitCond) {
    SmallVector<BasicBlock *> ExitingBlocks;
    L->getExitingBlocks(ExitingBlocks);
    for (BasicBlock *Exiting : ExitingBlocks) {
      if (BranchInst *BI = dyn_cast<BranchInst>(Exiting->getTerminator())) {
        if (BI->isConditional()) {
          Value *Cond = BI->getCondition();
          if (auto *ICmp = dyn_cast<ICmpInst>(Cond)) {
            Value *Op0 = ICmp->getOperand(0);
            Value *Op1 = ICmp->getOperand(1);

            if (Op0 == CanonIV || Op1 == CanonIV) {
              ExitCond = ICmp;
              ExitBound = (Op0 == CanonIV) ? Op1 : Op0;
              break;
            }
          }
        }
      }
    }
  }

  if (!ExitCond || !ExitBound) {
    LLVM_DEBUG(dbgs() << "  No suitable exit condition found\n");
    return std::nullopt;
  }

  // Verify the bound is loop-invariant
  if (!L->isLoopInvariant(ExitBound)) {
    LLVM_DEBUG(dbgs() << "  Exit bound is not loop-invariant\n");
    return std::nullopt;
  }

  LLVM_DEBUG(dbgs() << "  Found exit bound: " << *ExitBound << "\n");
  LLVM_DEBUG(dbgs() << "  This is a counted loop!\n");

  CountedLoopInfo Info;
  Info.TheLoop = L;
  Info.InductionVar = CanonIV;
  Info.ExitBound = ExitBound;
  Info.ExitCond = ExitCond;

  return Info;
}

/// Find all safepoints instructions in a loop
SmallVector<CallInst *> findSafepointsInLoop(Loop *L) {
  SmallVector<CallInst *> Safepoints;

  for (BasicBlock *BB : L->blocks()) {
    for (Instruction &Inst : *BB) {
      if (CallInst *CI = dyn_cast<CallInst>(&Inst)) {
        LLVM_DEBUG(dbgs() << "  Check Call Inst: " << *CI << "\n");
        if (isSafepointCall(CI)) {
          Safepoints.push_back(CI);
        }
      }
    }
  }

  return Safepoints;
}

/// Eliminate safepoints from a counted loop
/// Returns true if any changes were made
bool eliminateSafepointsInLoop(const CountedLoopInfo &Info) {
  Loop *L = Info.TheLoop;

  // Find all safepoints in this loop
  SmallVector<CallInst *> Safepoints = findSafepointsInLoop(L);

  if (Safepoints.empty()) {
    LLVM_DEBUG(dbgs() << "  No safepoints found in this loop\n");
    return false;
  }

  LLVM_DEBUG(dbgs() << "  Found " << Safepoints.size()
                    << " safepoints to eliminate\n");

  // Remove all safepoints from the loop body
  for (CallInst *SP : Safepoints) {
    LLVM_DEBUG(dbgs() << "  Removing safepoint: " << *SP << "\n");
    SP->eraseFromParent();
  }

  return true;
}

} // end anonymous namespace

PreservedAnalyses SafepointElimination::run(Function &F,
                                            FunctionAnalysisManager &FAM) {
  LLVM_DEBUG(dbgs() << "Running SafepointElimination on " << F.getName()
                    << "\n");

  // Get required analyses
  auto &LI = FAM.getResult<LoopAnalysis>(F);

  bool Changed = false;

  for (Loop *L : LI) {
    // Check if it's the leaf loop
    if (!L->getSubLoops().empty()) {
      LLVM_DEBUG(dbgs() << "  Loop has nested sub-loops, skipping\n");
      continue;
    }

    // Check if this is a counted loop
    auto CountedLoop = checkCountedLoop(L);

    if (!CountedLoop.has_value()) {
      continue;
    }

    // Eliminate safepoints in this counted loop
    if (eliminateSafepointsInLoop(*CountedLoop)) {
      Changed = true;
    }
  }

  if (!Changed) {
    return PreservedAnalyses::all();
  }

  // Preserve analyses that remain valid after our transformations
  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>();
  PA.preserve<LoopAnalysis>();

  return PA;
}
