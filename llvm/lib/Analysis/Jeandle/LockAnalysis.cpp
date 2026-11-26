//===- LockAnalysis.cpp - Java monitor analysis helpers -----------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Analysis/Jeandle/LockAnalysis.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/Analysis/Jeandle/MonitorAnalysis.h"
#include "llvm/Analysis/Jeandle/PartialEscapeUtils.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Jeandle/JavaType.h"

#include <algorithm>
#include <cassert>
#include <deque>

using namespace llvm;
using namespace llvm::jeandle::lock;

#define DEBUG_TYPE "jeandle-lock-coarsening"

static Function *getDirectCallee(const CallInst &CI) {
  return dyn_cast<Function>(CI.getCalledOperand()->stripPointerCasts());
}

static std::optional<LockingMode> getLockingMode(StringRef Name) {
  if (Name.ends_with("_with_monitor_lock"))
    return LockingMode::Monitor;
  if (Name.ends_with("_with_thin_lock"))
    return LockingMode::Thin;
  if (Name.ends_with("_with_lightweight_lock"))
    return LockingMode::Lightweight;
  return std::nullopt;
}

std::optional<MonitorOp> llvm::jeandle::lock::getMonitorOp(Instruction &I) {
  // Monitor JavaOps are emitted by call_java_op and therefore are always
  // ordinary CallInsts.  Do not model invoke/callbr forms here.
  auto *CI = dyn_cast<CallInst>(&I);
  if (!CI || CI->arg_size() < 2)
    return std::nullopt;

  bool IsEnter = jeandle::pea::isJeandleMonitorEnter(CI);
  bool IsExit = jeandle::pea::isJeandleMonitorExit(CI);
  if (IsEnter == IsExit)
    return std::nullopt;

  Function *Callee = getDirectCallee(*CI);
  if (!Callee)
    return std::nullopt;

  std::optional<LockingMode> Mode = getLockingMode(Callee->getName());
  if (!Mode)
    return std::nullopt;

  assert(CI->doesNotThrow() && "monitor JavaOp must be nounwind");

  return MonitorOp{CI, CI->getArgOperand(0), CI->getArgOperand(1), *Mode,
                   IsEnter};
}

Value *llvm::jeandle::lock::stripMonitorIdentity(Value *V) {
  for (unsigned Depth = 0; Depth != 16; ++Depth) {
    V = V->stripPointerCastsAndAliases();
    if (auto *Freeze = dyn_cast<FreezeInst>(V)) {
      V = Freeze->getOperand(0);
      continue;
    }
    if (Value *Input = jeandle::getJavaIdentityInput(V)) {
      V = Input;
      continue;
    }
    break;
  }
  return V->stripPointerCastsAndAliases();
}

bool llvm::jeandle::lock::sameMonitorObject(const MonitorOp &A,
                                            const MonitorOp &B) {
  return stripMonitorIdentity(A.Object) == stripMonitorIdentity(B.Object);
}

bool llvm::jeandle::lock::sameMonitorLock(const MonitorOp &A,
                                          const MonitorOp &B) {
  return A.Lock->stripPointerCastsAndAliases() ==
         B.Lock->stripPointerCastsAndAliases();
}

bool llvm::jeandle::lock::isLifetimeMarker(const Instruction &I) {
  const auto *II = dyn_cast<IntrinsicInst>(&I);
  return II && (II->getIntrinsicID() == Intrinsic::lifetime_start ||
                II->getIntrinsicID() == Intrinsic::lifetime_end);
}

bool llvm::jeandle::lock::isBoundaryTransparent(const Instruction &I) {
  if (isa<DbgInfoIntrinsic>(I) || isLifetimeMarker(I))
    return true;
  return !isa<CallBase>(I) && !isa<PHINode>(I) && !I.isTerminator() &&
         !I.mayReadOrWriteMemory() && !I.mayHaveSideEffects();
}

Value *llvm::jeandle::lock::getLifetimePointer(IntrinsicInst &II) {
  if (!isLifetimeMarker(II) || II.arg_empty())
    return nullptr;
  return II.getArgOperand(II.arg_size() - 1)->stripPointerCastsAndAliases();
}

bool llvm::jeandle::lock::isLifetimeFor(Instruction *I, Intrinsic::ID ID,
                                        Value *V) {
  auto *II = dyn_cast_or_null<IntrinsicInst>(I);
  return II && II->getIntrinsicID() == ID &&
         getLifetimePointer(*II) == V->stripPointerCastsAndAliases();
}

std::optional<MonitorOp>
llvm::jeandle::lock::previousMonitorOp(Instruction &From) {
  for (auto It = From.getIterator(); It != From.getParent()->begin();) {
    --It;
    if (std::optional<MonitorOp> Op = getMonitorOp(*It))
      return Op;
  }
  return std::nullopt;
}

Instruction *
llvm::jeandle::lock::nextNonTransparent(Instruction &From,
                                        SmallVectorImpl<Instruction *> *Seen) {
  for (auto It = std::next(From.getIterator()), End = From.getParent()->end();
       It != End; ++It) {
    if (!isBoundaryTransparent(*It))
      return &*It;
    if (Seen && isLifetimeMarker(*It))
      Seen->push_back(&*It);
  }
  return nullptr;
}

IntrinsicInst *
llvm::jeandle::lock::findSecondLifetimeEnd(const MonitorOp &SecondExit) {
  for (auto It = std::next(SecondExit.Call->getIterator()),
            End = SecondExit.Call->getParent()->end();
       It != End && isBoundaryTransparent(*It); ++It) {
    auto *II = dyn_cast<IntrinsicInst>(&*It);
    if (II && II->getIntrinsicID() == Intrinsic::lifetime_end &&
        getLifetimePointer(*II) ==
            SecondExit.Lock->stripPointerCastsAndAliases())
      return II;
  }
  return nullptr;
}

MonitorRegion
llvm::jeandle::lock::getMonitorRegion(const AdjacentRegion &Region) {
  assert(Region.First.Enter && Region.Second.Enter &&
         "adjacent region must have two enters");
  // A rewrite retains exactly the first enter.  Everything else in the
  // candidate is redundant; in particular the candidate never merges two
  // independent entries into a single physical monitor.
  assert(Region.First.Enter.Call != Region.Second.Enter.Call &&
         "adjacent region reused the same monitor enter");
  MonitorRegion Common;
  Common.RetainedEnter = Region.First.Enter;
  Common.LifetimeMarkersToErase.assign(Region.BoundaryLifetimeMarkers.begin(),
                                       Region.BoundaryLifetimeMarkers.end());
  for (const MonitorExit &Exit : Region.Second.Exits) {
    Common.RetainedExits.push_back(Exit.Op);
    if (Exit.LifetimeEnd &&
        !llvm::is_contained(Common.LifetimeMarkersToKeep, Exit.LifetimeEnd))
      Common.LifetimeMarkersToKeep.push_back(Exit.LifetimeEnd);
  }
  Common.RegionCalls.assign(Region.FirstRegionCalls.begin(),
                            Region.FirstRegionCalls.end());
  for (CallBase *Call : Region.SecondRegionCalls)
    if (!llvm::is_contained(Common.RegionCalls, Call))
      Common.RegionCalls.push_back(Call);

  // Straight-line candidate: First.Exits and Second.Enter fold into the
  // retained First.Enter, while the second region's exits become the retained
  // exits.
  for (const MonitorExit &Exit : Region.First.Exits)
    Common.RemovedMonitorOps.push_back(Exit.Op);
  Common.RemovedMonitorOps.push_back(Region.Second.Enter);
  return Common;
}

bool llvm::jeandle::lock::hasOnlyExpectedLockSlotUses(
    const MonitorRegion &Region, Value *RetainedLock) {
  SmallVector<Value *, 4> Slots;
  for (const MonitorOp &Op : Region.RemovedMonitorOps)
    if (!llvm::is_contained(Slots, Op.Lock->stripPointerCastsAndAliases()))
      Slots.push_back(Op.Lock->stripPointerCastsAndAliases());
  // A retained exit may itself name a discarded slot; its uses must be
  // audited just like the slots named by removed monitor operations.
  for (const MonitorOp &Exit : Region.RetainedExits)
    if (!llvm::is_contained(Slots, Exit.Lock->stripPointerCastsAndAliases()))
      Slots.push_back(Exit.Lock->stripPointerCastsAndAliases());

  for (Value *Lock : Slots) {
    if (Lock == RetainedLock->stripPointerCastsAndAliases())
      continue;

    auto *Slot = dyn_cast<AllocaInst>(Lock);
    if (!Slot)
      return false;

    for (const Use &U : Slot->uses()) {
      const User *Usr = U.getUser();
      if (llvm::any_of(Region.RemovedMonitorOps,
                       [Usr](const MonitorOp &Op) { return Usr == Op.Call; }))
        continue;
      if (llvm::any_of(Region.RetainedExits, [Usr](const MonitorOp &Exit) {
            return Usr == Exit.Call;
          }))
        continue;
      // A removed monitor exit may name its BasicLock in the deopt bundle of
      // the same call.  Those calls are already in RegionCalls and are handled
      // by hasOnlyRewritableDeoptLockUses.
      if (llvm::is_contained(Region.RegionCalls, dyn_cast<CallBase>(Usr)))
        continue;
      if (llvm::is_contained(Region.LifetimeMarkersToErase,
                             dyn_cast<Instruction>(Usr)) ||
          llvm::is_contained(Region.LifetimeMarkersToKeep,
                             dyn_cast<Instruction>(Usr)))
        continue;
      return false;
    }
  }
  return true;
}

bool llvm::jeandle::lock::hasOnlyRewritableDeoptLockUses(
    const MonitorRegion &Region, ArrayRef<Value *> DiscardedLocks,
    Value *RetainedObject) {
  for (CallBase *CB : Region.RegionCalls) {
    if (!CB->getOperandBundle(LLVMContext::OB_deopt))
      continue;

    // A non-parsable bundle cannot prove which cells refer to a discarded
    // slot, so the candidate must be rejected.
    auto Parsed = jeandle::pea::parseDeoptBundle(*CB);
    if (!Parsed.Bundle)
      return false;

    OperandBundleUse Deopt = *CB->getOperandBundle(LLVMContext::OB_deopt);
    for (const jeandle::pea::DeoptStructuralCell &Cell :
         Parsed.Bundle->Fingerprint.Cells) {
      Value *Input = Deopt.Inputs[Cell.OperandIndex].get();
      if (!llvm::is_contained(DiscardedLocks,
                              Input->stripPointerCastsAndAliases()))
        continue;
      // A BasicLock slot is only meaningful in a monitor-lock cell.  Any other
      // cell (for example an original-PC value) cannot be rewritten by RAUW
      // without changing its semantics.
      if (Cell.Role != jeandle::pea::DeoptSemanticCellRole::MonitorLock)
        return false;
    }

    for (const jeandle::pea::ParsedDeoptScope &Scope : Parsed.Bundle->Scopes)
      for (const jeandle::pea::ParsedDeoptMonitor &Monitor : Scope.Monitors) {
        Value *Lock = Deopt.Inputs[Monitor.LockCell.OperandIndex].get();
        if (!llvm::is_contained(DiscardedLocks,
                                Lock->stripPointerCastsAndAliases()))
          continue;
        if (Monitor.Eliminated)
          return false;
        Value *Owner = Deopt.Inputs[Monitor.OwnerCell.OperandIndex].get();
        if (stripMonitorIdentity(Owner) != stripMonitorIdentity(RetainedObject))
          return false;
      }
  }
  return true;
}

//===----------------------------------------------------------------------===//
// Global monitor stack analysis
//===----------------------------------------------------------------------===//

bool LockStackState::operator==(const LockStackState &Other) const {
  if (HasUnknownOuter != Other.HasUnknownOuter ||
      Frames.size() != Other.Frames.size())
    return false;
  for (unsigned I = 0; I != Frames.size(); ++I)
    if (Frames[I] != Other.Frames[I])
      return false;
  return true;
}

bool LockRegion::hasExit(const CallInst *Exit) const {
  return llvm::is_contained(Exits, Exit);
}

static LockStackState mergeStates(const LockStackState &A,
                                  const LockStackState &B) {
  LockStackState Merged;
  unsigned Common = 0;
  unsigned Shared = std::min(A.Frames.size(), B.Frames.size());
  while (Common != Shared && A.Frames[A.Frames.size() - 1 - Common] ==
                                 B.Frames[B.Frames.size() - 1 - Common])
    ++Common;

  for (unsigned I = A.Frames.size() - Common; I != A.Frames.size(); ++I)
    Merged.Frames.push_back(A.Frames[I]);

  // Anything below the common suffix is no longer provable.  This includes
  // paths that already lost outer frames before reaching this join.
  Merged.HasUnknownOuter = A.HasUnknownOuter || B.HasUnknownOuter ||
                           A.Frames.size() != Common ||
                           B.Frames.size() != Common;
  return Merged;
}

/// Return true if Enter is the identity of the innermost known frame.
static bool isTop(const LockStackState &State, const CallInst *Enter) {
  if (State.Frames.empty())
    return false;
  const LockStackFrame &Top = State.Frames.back();
  return Top.isValid() && Top.Enter == Enter;
}

/// Drop every known frame.  The stack may still be non-empty, but none of its
/// frames can be identified at this point.
static void makeStackUnknown(LockStackState &State) {
  State.Frames.clear();
  State.HasUnknownOuter = true;
}

static bool isMonitorOp(const CallInst *CI) {
  return jeandle::pea::isJeandleMonitorEnter(CI) ||
         jeandle::pea::isJeandleMonitorExit(CI);
}

static LockStackFrame makeFrame(const MonitorOp &Op,
                                const jeandle::MonitorDepthInfo &Depth) {
  LockStackFrame Frame;
  Frame.Enter = Op.Call;
  Frame.Mode = Op.Mode;
  if (!Op.IsEnter)
    return Frame;

  std::optional<uint32_t> AbsoluteDepth = Depth.getAbsoluteLockDepth(Op.Call);
  if (AbsoluteDepth) {
    Frame.Object = stripMonitorIdentity(Op.Object);
    Frame.Lock = Op.Lock->stripPointerCastsAndAliases();
    Frame.BytecodeDepth = *AbsoluteDepth;
  }
  // An enter whose absolute depth is unavailable still increases nesting.
  // Keep the frame as an invalid sentinel so a later exit cannot match an
  // outer frame, while preserving the suffix below it.
  return Frame;
}

/// Record an exit against the current top frame without changing the stack.
static bool recordExit(const LockStackState &State, const MonitorOp &Exit,
                       DenseMap<const CallInst *, LockRegion> &Regions) {
  if (State.Frames.empty())
    return false;

  const LockStackFrame &Top = State.Frames.back();
  if (!Top.isValid() || Top.Mode != Exit.Mode ||
      Top.Object != stripMonitorIdentity(Exit.Object) ||
      Top.Lock != Exit.Lock->stripPointerCastsAndAliases())
    return false;

  auto It = Regions.find(Top.Enter);
  if (It == Regions.end())
    return false;

  if (!It->second.hasExit(Exit.Call))
    It->second.Exits.push_back(Exit.Call);
  return true;
}

/// Apply the transfer of one monitor operation.
static LockStackState
applyMonitorOp(const LockStackState &State, const CallInst &CI,
               const jeandle::MonitorDepthInfo &Depth,
               DenseMap<const CallInst *, LockRegion> &Regions) {
  LockStackState Next = State;
  std::optional<MonitorOp> Op =
      getMonitorOp(const_cast<Instruction &>(cast<Instruction>(CI)));
  if (!Op) {
    makeStackUnknown(Next);
    return Next;
  }

  if (Op->IsEnter) {
    LockStackFrame Frame = makeFrame(*Op, Depth);
    Next.Frames.push_back(Frame);
    LockRegion &Region = Regions[Op->Call];
    Region.Enter = Op->Call;
    Region.Frame = Frame;
    return Next;
  }

  if (Next.Frames.empty()) {
    // A release without a known acquire can only be represented as an
    // unknown outer frame.  It is not a globally fatal structure error.
    makeStackUnknown(Next);
    return Next;
  }

  if (!recordExit(State, *Op, Regions)) {
    // The release does not match the current top.  Do not let malformed or
    // partially lowered IR manufacture a local stack fact.
    makeStackUnknown(Next);
    return Next;
  }
  Next.Frames.pop_back();
  return Next;
}

LockStackAnalysis::LockStackAnalysis(Function &F) {
  const jeandle::MonitorDepthInfo Depth = jeandle::computeMonitorDepthInfo(F);

  DenseMap<const BasicBlock *, LockStackState> Incoming;
  SmallVector<const BasicBlock *, 32> Worklist;
  LockStackState EntryState;
  // OSR roots may enter with interpreter-held monitors.
  EntryState.HasUnknownOuter = Depth.EntryDepth != 0;
  Incoming[&F.getEntryBlock()] = EntryState;
  Worklist.push_back(&F.getEntryBlock());

  while (!Worklist.empty()) {
    const BasicBlock *BB = Worklist.pop_back_val();
    const LockStackState Entry = Incoming.lookup(BB);
    LockStackState Current = Entry;

    for (const Instruction &I : *BB) {
      auto *CI = dyn_cast<CallInst>(&I);
      if (!CI || !isMonitorOp(CI))
        continue;

      StatesBefore[&I] = Current;
      Current = applyMonitorOp(Current, *CI, Depth, Regions);
      StatesAfter[&I] = Current;
    }

    for (const BasicBlock *Succ : successors(BB)) {
      auto [It, Inserted] = Incoming.try_emplace(Succ, Current);
      bool Changed = Inserted;
      if (!Inserted) {
        LockStackState Merged = mergeStates(It->second, Current);
        if (Merged != It->second) {
          It->second = Merged;
          Changed = true;
        }
      }
      if (Changed)
        Worklist.push_back(Succ);
    }
  }
}

const LockStackState *
LockStackAnalysis::getStateBefore(const Instruction &I) const {
  auto It = StatesBefore.find(&I);
  return It == StatesBefore.end() ? nullptr : &It->second;
}

const LockStackState *
LockStackAnalysis::getStateAfter(const Instruction &I) const {
  auto It = StatesAfter.find(&I);
  return It == StatesAfter.end() ? nullptr : &It->second;
}

bool LockStackAnalysis::provesAdjacentRegion(
    const AdjacentRegion &Region) const {
  assert(!Region.First.Exits.empty() && !Region.Second.Exits.empty() &&
         "incomplete adjacent monitor region");
  const CallInst *FirstEnter = Region.First.Enter.Call;
  // The straight-line candidate currently requires the first region to have
  // exactly one lexical exit; LockStructureVerifier enforces that invariant
  // before this proof runs.  The second region may still have multiple exits
  // when an invoke leaves it through both its normal and unwind edges.
  assert(Region.First.Exits.size() == 1 &&
         "adjacent candidate must have a single first exit");
  const CallInst *FirstExit = Region.First.Exits.front().Op.Call;
  const CallInst *SecondEnter = Region.Second.Enter.Call;
  assert(FirstEnter && FirstExit && SecondEnter &&
         "incomplete adjacent monitor region");

  const LockStackState *BeforeFirstExit = getStateBefore(*FirstExit);
  const LockStackState *AfterFirstExit = getStateAfter(*FirstExit);
  const LockStackState *BeforeSecondEnter = getStateBefore(*SecondEnter);
  const LockStackState *AfterSecondEnter = getStateAfter(*SecondEnter);
  if (!BeforeFirstExit || !AfterFirstExit || !BeforeSecondEnter ||
      !AfterSecondEnter)
    return false;

  const LockRegion *FirstRegion = getRegionForEnter(FirstEnter);
  const LockRegion *SecondRegion = getRegionForEnter(SecondEnter);
  if (!FirstRegion || !SecondRegion || !FirstRegion->hasExit(FirstExit) ||
      SecondRegion->Exits.size() != Region.Second.Exits.size())
    return false;

  // The first exit must release the current top frame.
  if (!isTop(*BeforeFirstExit, FirstEnter))
    return false;

  // The sibling second enter must observe exactly the stack left by the
  // first exit.  The candidate builder has already restricted the gap to one
  // basic block and transparent instructions.
  if (*AfterFirstExit != *BeforeSecondEnter)
    return false;

  // The second enter must be the new top, and its exit must release it.
  if (!isTop(*AfterSecondEnter, SecondEnter))
    return false;

  for (const MonitorExit &SecondExit : Region.Second.Exits) {
    if (!SecondExit.Op.Call || !SecondRegion->hasExit(SecondExit.Op.Call))
      return false;

    const LockStackState *BeforeSecondExit =
        getStateBefore(*SecondExit.Op.Call);
    const LockStackState *AfterSecondExit = getStateAfter(*SecondExit.Op.Call);
    if (!BeforeSecondExit || !AfterSecondExit ||
        !isTop(*BeforeSecondExit, SecondEnter))
      return false;

    // Every exit must pop exactly the frame pushed by the second enter and
    // restore the stack observed before that enter.
    if (*AfterSecondExit != *BeforeSecondEnter)
      return false;
  }
  return true;
}

const LockRegion *
LockStackAnalysis::getRegionForEnter(const CallInst *Enter) const {
  auto It = Regions.find(Enter);
  return It == Regions.end() ? nullptr : &It->second;
}
