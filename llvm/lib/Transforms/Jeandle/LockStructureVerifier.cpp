//===- LockStructureVerifier.cpp - Verify a coarsening candidate ----------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/LockStructureVerifier.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/Jeandle/LockAnalysis.h"
#include "llvm/Analysis/Jeandle/PartialEscapeUtils.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"

#include <cassert>

using namespace llvm;
using namespace llvm::jeandle::lock;

static bool fail(std::string *Reason, StringRef Message) {
  if (Reason)
    *Reason = Message.str();
  return false;
}

static bool inSameBlock(const Instruction *A, const Instruction *B) {
  return A && B && A->getParent() && A->getParent() == B->getParent();
}

/// Return true if A and B are distinct instructions in the same basic block
/// and A appears before B.
static bool comesBefore(const Instruction *A, const Instruction *B) {
  if (!inSameBlock(A, B) || A == B)
    return false;
  for (const Instruction &I : *A->getParent()) {
    if (&I == A)
      return true;
    if (&I == B)
      return false;
  }
  return false;
}

static bool isSafeEarlyExitForVerify(const Instruction &I) {
  if (isa<ReturnInst>(I))
    return true;
  const auto *CB = dyn_cast<CallBase>(&I);
  return CB && CB->getIntrinsicID() == Intrinsic::experimental_deoptimize;
}

static bool isSameSlot(Value *A, Value *B) {
  return A && B &&
         A->stripPointerCastsAndAliases() == B->stripPointerCastsAndAliases();
}

/// A deopt termination path keeps the retained monitor active, so its bundle
/// must still name the retained BasicLock.  Anything else could deopt with a
/// monitor state that no longer matches the rewritten IR.
static bool deoptPreservesLock(CallInst &Deopt, Value *RetainedLock,
                               Value *DiscardedLock, Value *RetainedObject) {
  if (Deopt.getIntrinsicID() != Intrinsic::experimental_deoptimize)
    return true;
  if (!Deopt.getOperandBundle(LLVMContext::OB_deopt))
    return false;
  auto Parsed = jeandle::pea::parseDeoptBundle(Deopt);
  if (!Parsed.Bundle)
    return false;
  OperandBundleUse DeoptInputs = *Deopt.getOperandBundle(LLVMContext::OB_deopt);
  for (const jeandle::pea::ParsedDeoptScope &Scope : Parsed.Bundle->Scopes)
    for (const jeandle::pea::ParsedDeoptMonitor &Monitor : Scope.Monitors) {
      if (Monitor.Eliminated)
        continue;
      Value *Lock = DeoptInputs.Inputs[Monitor.LockCell.OperandIndex].get();
      // The bundle may still name the second region's slot before slot
      // normalization rewrites it to the retained slot.
      if (!isSameSlot(Lock, RetainedLock) && !isSameSlot(Lock, DiscardedLock))
        continue;
      Value *Owner = DeoptInputs.Inputs[Monitor.OwnerCell.OperandIndex].get();
      return stripMonitorIdentity(Owner) ==
             stripMonitorIdentity(RetainedObject);
    }
  return false;
}

bool LockStructureVerifier::verifyAdjacentShape(const AdjacentRegion &Region,
                                                const LockStackAnalysis &Stack,
                                                const DominatorTree &DT,
                                                std::string *Reason) const {
  const MonitorOp &FirstEnter = Region.First.Enter;
  const MonitorOp &SecondEnter = Region.Second.Enter;

  // Basic shape: two balanced regions with the mandatory monitor operations.
  if (!FirstEnter.Call || !SecondEnter.Call || Region.First.Exits.empty() ||
      Region.Second.Exits.empty())
    return fail(Reason, "missing monitor operation");

  // The straight-line candidate folds the first region before the transparent
  // boundary, so it currently requires exactly one lexical first exit.
  if (Region.First.Exits.size() != 1)
    return fail(Reason, "straight-line first region has multiple exits");
  const MonitorOp &FirstExit = Region.First.Exits.front().Op;

  if (!FirstEnter.IsEnter || FirstExit.IsEnter || !SecondEnter.IsEnter)
    return fail(Reason, "monitor enter/exit direction is inconsistent");

  // Monitor operations may now sit in different blocks.  Dominance replaces
  // the old same-block ordering check, and the scanner's block set proves that
  // each operation really belongs to its region.
  if (!DT.dominates(FirstEnter.Call, FirstExit.Call) ||
      !DT.dominates(FirstExit.Call, SecondEnter.Call))
    return fail(Reason, "monitor operations are not in region order");

  if (Region.FirstRegionBlocks.empty() ||
      !llvm::is_contained(Region.FirstRegionBlocks,
                          FirstEnter.Call->getParent()) ||
      !llvm::is_contained(Region.FirstRegionBlocks,
                          FirstExit.Call->getParent()))
    return fail(Reason, "first region has no CFG coverage set");

  if (!sameMonitorObject(FirstEnter, FirstExit) ||
      !sameMonitorObject(FirstExit, SecondEnter) ||
      !sameMonitorLock(FirstEnter, FirstExit))
    return fail(Reason, "monitor object or lock slot does not match");

  if (Region.SecondRegionBlocks.empty() ||
      !llvm::is_contained(Region.SecondRegionBlocks,
                          SecondEnter.Call->getParent()))
    return fail(Reason, "second region has no CFG coverage set");

  // Second-region exits: each must match the enter and stay on its region.
  for (const MonitorExit &SecondExit : Region.Second.Exits) {
    if (!SecondExit.Op.Call || SecondExit.Op.IsEnter)
      return fail(Reason, "monitor enter/exit direction is inconsistent");
    if (SecondExit.Op.Mode != SecondEnter.Mode ||
        !sameMonitorObject(SecondExit.Op, SecondEnter) ||
        !sameMonitorLock(SecondExit.Op, SecondEnter))
      return fail(Reason, "second region exit does not match its enter");

    if (SecondExit.Op.Call->getParent() == SecondEnter.Call->getParent()) {
      if (!comesBefore(SecondEnter.Call, SecondExit.Op.Call))
        return fail(Reason, "second exit is not after the second enter");
      continue;
    }

    // The candidate scanner enumerated the second region's CFG.  The exit may
    // live in any visited block, but not in a block reached only outside that
    // region (for example catch dispatch after the lock was released).
    if (!llvm::is_contained(Region.SecondRegionBlocks,
                            SecondExit.Op.Call->getParent()))
      return fail(Reason, "second exit is outside the second region");
  }

  // Deopt termination blocks inside either region keep the retained lock
  // active and must not perform any monitor operation of their own.  Their
  // bundle is the only place that may observe the lock, and it must still
  // describe the retained monitor.  In the first region the discarded slot is
  // the first exit's slot (normally the same alloca); in the second region it
  // is the second enter's slot.
  Value *RetainedSlot = FirstEnter.Lock->stripPointerCastsAndAliases();
  auto VerifyDeoptBlocks = [&](ArrayRef<BasicBlock *> Blocks,
                               Value *DiscardedSlot) -> bool {
    for (BasicBlock *BB : Blocks) {
      CallInst *Deopt = nullptr;
      for (Instruction &I : *BB) {
        if (getMonitorOp(I))
          continue;
        auto *Call = dyn_cast<CallInst>(&I);
        if (!Call)
          continue;
        if (Call->getIntrinsicID() == Intrinsic::experimental_deoptimize) {
          if (Deopt)
            return fail(Reason, "region has multiple deopts in a block");
          Deopt = Call;
          continue;
        }
      }
      if (!Deopt)
        continue;

      Instruction *After = Deopt->getNextNode();
      while (After &&
             (isa<DbgInfoIntrinsic>(After) || isLifetimeMarker(*After)))
        After = After->getNextNode();
      if (!After || !isa<ReturnInst>(*After))
        return fail(Reason, "deopt termination is not followed by return");
      if (!deoptPreservesLock(*Deopt, RetainedSlot, DiscardedSlot,
                              FirstEnter.Object))
        return fail(Reason, "deopt termination lost the retained monitor");
    }
    return true;
  };
  if (!VerifyDeoptBlocks(Region.FirstRegionBlocks, FirstExit.Lock) ||
      !VerifyDeoptBlocks(Region.SecondRegionBlocks, SecondEnter.Lock))
    return false;

  // Stack proof: the first exit and second region must operate on the exact
  // frames expected by the straight-line rewrite.
  if (!Stack.provesAdjacentRegion(Region))
    return fail(Reason, "monitor stack shape is not a proven adjacent region");

  // Lexical boundary: the second region must immediately follow the first
  // normal exit, with a complete and accurate list of transparent lifetime
  // markers.  For a single-block first region this also proves that no other
  // monitor pair sits between the two regions.
  if (FirstEnter.Call->getParent() == FirstExit.Call->getParent()) {
    std::optional<MonitorOp> Previous = previousMonitorOp(*FirstExit.Call);
    if (!Previous || Previous->Call != FirstEnter.Call)
      return fail(Reason, "first region is not the nearest monitor pair");
  }

  SmallVector<Instruction *, 4> SeenMarkers;
  Instruction *Next = nextNonTransparent(*FirstExit.Call, &SeenMarkers);
  if (Next != SecondEnter.Call)
    return fail(Reason, "second region is not immediately after first exit");
  if (SeenMarkers.size() != Region.BoundaryLifetimeMarkers.size() ||
      !llvm::equal(SeenMarkers, Region.BoundaryLifetimeMarkers))
    return fail(Reason, "boundary lifetime marker list is stale or incomplete");

  // Straight-line candidates have an additional lexical obligation: the
  // transparent boundary may only close the retained slot and start the
  // discarded slot.  Covered candidates do not have a single boundary, so this
  // direction-specific check stays here and the common proof handles both.
  Value *RetainedLock = FirstExit.Lock->stripPointerCastsAndAliases();
  Value *DiscardedLock = SecondEnter.Lock->stripPointerCastsAndAliases();
  unsigned RetainedEnds = 0;
  unsigned DiscardedStarts = 0;
  for (Instruction *Marker : Region.BoundaryLifetimeMarkers) {
    auto *II = dyn_cast<IntrinsicInst>(Marker);
    assert(II && isLifetimeMarker(*II) &&
           "boundary marker is not a lifetime intrinsic");

    Value *Ptr = getLifetimePointer(*II);
    if (isSameSlot(Ptr, RetainedLock) && isSameSlot(Ptr, DiscardedLock)) {
      if (II->getIntrinsicID() == Intrinsic::lifetime_end)
        ++RetainedEnds;
      else if (II->getIntrinsicID() == Intrinsic::lifetime_start)
        ++DiscardedStarts;
      else
        return fail(Reason, "unexpected lifetime marker kind");
      continue;
    } else if (isSameSlot(Ptr, RetainedLock)) {
      if (II->getIntrinsicID() != Intrinsic::lifetime_end)
        return fail(Reason, "retained slot has an unexpected lifetime.start");
      ++RetainedEnds;
      continue;
    } else if (isSameSlot(Ptr, DiscardedLock)) {
      if (II->getIntrinsicID() != Intrinsic::lifetime_start)
        return fail(Reason, "discarded slot has an unexpected lifetime.end");
      ++DiscardedStarts;
      continue;
    }
    return fail(Reason,
                "boundary lifetime marker belongs to an unrelated alloca");
  }
  if (RetainedEnds > 1 || DiscardedStarts > 1)
    return fail(Reason, "duplicate boundary lifetime markers for a lock slot");

  return true;
}

bool LockStructureVerifier::verifyBeforeRewrite(const MonitorRegion &Region,
                                                const LockStackAnalysis *Stack,
                                                std::string *Reason) const {
  const MonitorOp &Retained = Region.RetainedEnter;

  // Basic structure: one retained enter and at least one removed operation.
  if (!Retained.Call || !Retained.IsEnter || Region.RemovedMonitorOps.empty())
    return fail(Reason, "missing monitor region");
  if (!Retained.Call->getParent())
    return fail(Reason, "retained enter has no parent block");

  // Retained exits: they must release the retained monitor, and the monitor
  // stack at each exit must be consistent with this rewrite.
  for (const MonitorOp &Exit : Region.RetainedExits) {
    if (!Exit.Call || Exit.IsEnter || Exit.Mode != Retained.Mode ||
        !sameMonitorObject(Exit, Retained))
      return fail(Reason, "retained exit does not match the retained enter");

    if (!Stack)
      continue;
    const LockStackState *BeforeExit = Stack->getStateBefore(*Exit.Call);
    if (!BeforeExit || BeforeExit->Frames.empty())
      return fail(Reason, "retained exit has no monitor stack state");
    const LockStackFrame &Top = BeforeExit->Frames.back();
    bool TopIsRemoved =
        llvm::any_of(Region.RemovedMonitorOps, [&](const MonitorOp &Op) {
          return Op.IsEnter && Op.Call == Top.Enter;
        });
    if (!TopIsRemoved && Top.Enter != Retained.Call)
      return fail(Reason, "retained exit releases an unremoved inner frame");
  }

  // Removed operations: they must belong to the same monitor region and must
  // not precede the retained acquisition in the same block.
  for (const MonitorOp &Op : Region.RemovedMonitorOps) {
    if (!Op.Call || Op.Mode != Retained.Mode ||
        !sameMonitorObject(Op, Retained))
      return fail(Reason,
                  "removed monitor operation does not match the region");
    if (Op.Call->getParent() == Retained.Call->getParent() &&
        !comesBefore(Retained.Call, Op.Call))
      return fail(Reason, "removed monitor operation precedes the region");
  }

  // Discarded slots: collect every BasicLock that normalization would replace.
  Value *RetainedLock = Retained.Lock->stripPointerCastsAndAliases();
  SmallVector<Value *, 4> DiscardedLocks;
  for (const MonitorOp &Op : Region.RemovedMonitorOps) {
    Value *Lock = Op.Lock->stripPointerCastsAndAliases();
    if (Lock != RetainedLock && !llvm::is_contained(DiscardedLocks, Lock))
      DiscardedLocks.push_back(Lock);
  }
  for (const MonitorOp &Exit : Region.RetainedExits) {
    Value *Lock = Exit.Lock->stripPointerCastsAndAliases();
    if (Lock != RetainedLock && !llvm::is_contained(DiscardedLocks, Lock))
      DiscardedLocks.push_back(Lock);
  }

  // Slot and deopt safety: discarded slots may only feed the rewritable uses,
  // and every referencing deopt monitor record must be mechanically fixable.
  if (!hasOnlyExpectedLockSlotUses(Region, RetainedLock))
    return fail(Reason, "discarded slot has a use outside the region");
  if (!hasOnlyRewritableDeoptLockUses(Region, DiscardedLocks, Retained.Object))
    return fail(Reason, "deopt monitor record cannot be rewritten safely");
  // Early exits: each side path must leave the frame through a return/deopt,
  // restore the outer monitor stack, and insert the retained unlock safely.
  if (!Region.EarlyExitPoints.empty()) {
    const LockStackState *BeforeRetained =
        Stack ? Stack->getStateBefore(*Retained.Call) : nullptr;
    const LockStackState *AfterRetained =
        Stack ? Stack->getStateAfter(*Retained.Call) : nullptr;
    if (Stack &&
        (!BeforeRetained || !AfterRetained || AfterRetained->Frames.empty() ||
         AfterRetained->Frames.back().Enter != Retained.Call))
      return fail(Reason, "retained enter has no valid monitor state");

    for (const MonitorRegion::EarlyExit &Early : Region.EarlyExitPoints) {
      Instruction *Point = Early.Point;
      if (!Point || !Point->getParent())
        return fail(Reason, "early exit point has no parent block");
      if (!isSafeEarlyExitForVerify(*Point))
        return fail(Reason, "early exit point is not a deopt or return");

      BasicBlock *BB = Point->getParent();
      if (!isa<ReturnInst>(*Point)) {
        if (Point->getNextNode() != BB->getTerminator() ||
            !isa<ReturnInst>(*BB->getTerminator()))
          return fail(
              Reason,
              "deopt early exit is not the final operation before return");
        for (const Instruction &I : *BB) {
          if (&I == Point)
            break;
          if (getMonitorOp(const_cast<Instruction &>(I)))
            return fail(Reason,
                        "early exit block contains a monitor operation");
          if (auto *CB = dyn_cast<CallBase>(&I))
            if (CB->getIntrinsicID() != Intrinsic::experimental_deoptimize)
              return fail(Reason,
                          "early exit block contains an observable call");
        }
      }

      if (!Early.BeforeBranch || !Early.BeforeBranch->getParent())
        return fail(Reason, "early exit has no preceding monitor exit");
      BasicBlock *BranchBB = Early.BeforeBranch->getParent();
      auto *Br = dyn_cast<BranchInst>(BranchBB->getTerminator());
      if (!Br || Br->isUnconditional() ||
          !llvm::is_contained(successors(BranchBB), Point->getParent()) ||
          Point->getParent()->getSinglePredecessor() != BranchBB)
        return fail(Reason, "early exit is not on the unique branch edge");

      if (Stack) {
        const LockStackState *AfterExit =
            Stack->getStateAfter(*Early.BeforeBranch);
        if (!AfterExit || !BeforeRetained || !AfterRetained ||
            *AfterExit != *BeforeRetained)
          return fail(Reason,
                      "intermediate exit does not restore the outer stack");
        if (AfterRetained->Frames.empty() ||
            AfterRetained->Frames.back().Enter != Retained.Call)
          return fail(Reason, "retained frame is not top at the early exit");
      } else if (!comesBefore(Retained.Call, Point)) {
        return fail(Reason, "early exit precedes the retained enter");
      }
    }
  }

  return true;
}
