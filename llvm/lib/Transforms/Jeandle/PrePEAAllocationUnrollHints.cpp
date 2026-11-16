//===- PrePEAAllocationUnrollHints.cpp - Allocation hints ----------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/PrePEAAllocationUnrollHints.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/AssumptionCache.h"
#include "llvm/Analysis/CodeMetrics.h"
#include "llvm/Analysis/Jeandle/PartialEscapeUtils.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/OptimizationRemarkEmitter.h"
#include "llvm/Analysis/ScalarEvolution.h"
#include "llvm/Analysis/TargetTransformInfo.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Metadata.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Transforms/Utils/LoopUtils.h"
#include "llvm/Transforms/Utils/UnrollLoop.h"

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

unsigned getPrePEAFullUnrollMaxCount() {
  return JeandlePrePEAFullUnrollMaxCount;
}

// Array scalar replacement can remove memory traffic exposed by unrolling.
// The standard unroller retains ownership of legality and transformation.
PreservedAnalyses
PrePEAAllocationUnrollHints::run(Function &F, FunctionAnalysisManager &FAM) {
  constexpr uint64_t MaxLoopCost = 1024;
  uint64_t RemainingCost = 4096;
  auto &LI = FAM.getResult<LoopAnalysis>(F);
  auto &SE = FAM.getResult<ScalarEvolutionAnalysis>(F);
  auto &TTI = FAM.getResult<TargetIRAnalysis>(F);
  auto &AC = FAM.getResult<AssumptionAnalysis>(F);
  auto &ORE = FAM.getResult<OptimizationRemarkEmitterAnalysis>(F);
  bool Changed = false;
  for (Loop *L : LI.getLoopsInPreorder()) {
    // Inner-loop expansion changes the cost of enclosing loops. Only hint
    // innermost loops so the function budget measures the IR being copied.
    if (!L->isInnermost() || hasUnrollTransformation(L) != TM_Unspecified)
      continue;
    unsigned Count = 0;
    SmallVector<BasicBlock *, 4> Exits;
    L->getExitingBlocks(Exits);
    for (BasicBlock *Exit : Exits)
      if (unsigned ExitCount = SE.getSmallConstantTripCount(L, Exit))
        if (!Count || ExitCount < Count)
          Count = ExitCount;
    if (Count < 2 || Count > JeandlePrePEAFullUnrollMaxCount)
      continue;

    bool HasArrayAccess = false;
    for (BasicBlock *BB : L->blocks()) {
      for (Instruction &I : *BB) {
        Value *Pointer = nullptr;
        if (auto *Load = dyn_cast<LoadInst>(&I))
          Pointer = Load->getPointerOperand();
        else if (auto *Store = dyn_cast<StoreInst>(&I))
          Pointer = Store->getPointerOperand();
        if (!Pointer)
          continue;
        auto *Allocation = dyn_cast<CallBase>(getUnderlyingObject(Pointer));
        if (!Allocation || L->contains(Allocation))
          continue;
        auto *Length = dyn_cast_or_null<ConstantInt>(
            pea::getJeandleNewArrayLength(Allocation));
        if (Length && !Length->isNegative() &&
            Length->getValue().ule(JeandlePrePEAFullUnrollMaxCount)) {
          HasArrayAccess = true;
          break;
        }
      }
      if (HasArrayAccess)
        break;
    }
    if (!HasArrayAccess)
      continue;

    auto UP = gatherUnrollingPreferences(
        L, SE, TTI, nullptr, nullptr, ORE, /*OptLevel=*/3, std::nullopt,
        std::nullopt, /*UserAllowPartial=*/false, /*UserRuntime=*/false,
        /*UserUpperBound=*/false, JeandlePrePEAFullUnrollMaxCount);
    SmallPtrSet<const Value *, 32> EphemeralValues;
    CodeMetrics::collectEphemeralValues(L, &AC, EphemeralValues);
    UnrollCostEstimator Cost(L, TTI, EphemeralValues, UP.BEInsns);
    if (!UP.Threshold || Count > UP.FullUnrollMaxCount || !Cost.canUnroll() ||
        Cost.NumInlineCandidates || Cost.getRolledLoopSize() < UP.BEInsns)
      continue;
    uint64_t UnrolledCost = Cost.getUnrolledLoopSize(UP, Count);
    if (UnrolledCost <= UP.Threshold || UnrolledCost > MaxLoopCost ||
        UnrolledCost > RemainingCost)
      continue;
    SmallVector<llvm::Metadata *, 8> LoopMetadata(1);
    if (MDNode *LoopID = L->getLoopID())
      for (unsigned I = 1; I < LoopID->getNumOperands(); ++I)
        LoopMetadata.push_back(LoopID->getOperand(I));
    LoopMetadata.push_back(
        MDNode::get(F.getContext(),
                    MDString::get(F.getContext(), "llvm.loop.unroll.full")));
    MDNode *LoopID = MDNode::getDistinct(F.getContext(), LoopMetadata);
    LoopID->replaceOperandWith(0, LoopID);
    L->setLoopID(LoopID);
    RemainingCost -= UnrolledCost;
    Changed = true;
  }
  if (!Changed)
    return PreservedAnalyses::all();
  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>();
  PA.preserve<ScalarEvolutionAnalysis>();
  return PA;
}
} // namespace llvm::jeandle
