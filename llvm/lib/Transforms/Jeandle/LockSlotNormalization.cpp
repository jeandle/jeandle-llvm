//===- LockSlotNormalization.cpp - Retain one Java BasicLock slot ---------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/LockSlotNormalization.h"
#include "llvm/Analysis/Jeandle/LockAnalysis.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"

using namespace llvm;
using namespace llvm::jeandle::lock;

LockSlotNormalization
llvm::jeandle::lock::planLockSlotNormalization(const MonitorRegion &Region) {
  LockSlotNormalization Plan;
  Plan.RetainedLock = Region.RetainedEnter.Lock->stripPointerCastsAndAliases();
  auto AddDiscarded = [&](Value *Lock) {
    if (!Lock)
      return;
    Value *Slot = Lock->stripPointerCastsAndAliases();
    if (Slot != Plan.RetainedLock &&
        !llvm::is_contained(Plan.DiscardedLocks, Slot))
      Plan.DiscardedLocks.push_back(Slot);
  };
  for (const MonitorOp &Op : Region.RemovedMonitorOps)
    AddDiscarded(Op.Lock);
  for (const MonitorOp &Exit : Region.RetainedExits)
    AddDiscarded(Exit.Lock);
  if (!Region.RetainedExits.empty())
    Plan.ExitTemplate = Region.RetainedExits.front().Call;
  return Plan;
}

void llvm::jeandle::lock::applyLockSlotNormalization(
    MonitorRegion &Region, const LockSlotNormalization &Plan) {
  for (Instruction *I : Region.LifetimeMarkersToErase)
    if (I && I->getParent())
      I->eraseFromParent();

  for (Value *Lock : Plan.DiscardedLocks)
    if (Lock && Lock != Plan.RetainedLock && Lock->getType() ==
                                                 Plan.RetainedLock->getType())
      Lock->replaceAllUsesWith(Plan.RetainedLock);

  // A path may leave the coarsened region before the retained exit, typically
  // through a deopt or exceptional return.  Clone the retained unlock onto
  // every such edge before erasing the original region operations.
  assert(!Region.EarlyExitPoints.empty() || !Plan.ExitTemplate ||
         "retained exit must exist when no early exit is introduced");
  for (const MonitorRegion::EarlyExit &Early : Region.EarlyExitPoints) {
    Instruction *Point = Early.Point;
    if (!Point || !Point->getParent())
      continue;
    CallInst *Exit = cast<CallInst>(Plan.ExitTemplate->clone());
    Exit->insertBefore(Point->getIterator());
  }

  for (const MonitorOp &Op : Region.RemovedMonitorOps)
    if (Op.Call && Op.Call->getParent())
      Op.Call->eraseFromParent();

  for (Value *Lock : Plan.DiscardedLocks) {
    auto *AI = dyn_cast_or_null<AllocaInst>(Lock);
    if (AI && AI->use_empty() && AI->getParent())
      AI->eraseFromParent();
  }
}
