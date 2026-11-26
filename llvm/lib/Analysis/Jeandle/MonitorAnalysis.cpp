//===- MonitorAnalysis.cpp - Shared Java monitor nesting analysis --------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Analysis/Jeandle/MonitorAnalysis.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/Jeandle/PartialEscapeUtils.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Intrinsics.h"

#include <algorithm>
#include <limits>

using namespace llvm;

bool llvm::jeandle::isDeoptContinuation(const BasicBlock *BB) {
  for (const Instruction &I : *BB)
    if (const auto *CB = dyn_cast<CallBase>(&I))
      if (const Function *Fn = CB->getCalledFunction())
        if (Fn->getIntrinsicID() == Intrinsic::experimental_deoptimize ||
            Fn->getName() == "__llvm_deoptimize")
          return true;
  return false;
}

std::optional<uint32_t> llvm::jeandle::MonitorDepthInfo::getAbsoluteLockDepth(
    const CallBase *Enter) const {
  if (!Valid)
    return std::nullopt;
  auto It = EnterRelativeDepth.find(const_cast<CallBase *>(Enter));
  if (It == EnterRelativeDepth.end())
    return std::nullopt;

  int64_t RelativeDepth = It->second;
  uint64_t AbsoluteDepth = EntryDepth;
  if (RelativeDepth < 0) {
    if (RelativeDepth == std::numeric_limits<int64_t>::min() ||
        static_cast<uint64_t>(-RelativeDepth) > AbsoluteDepth)
      return std::nullopt;
    AbsoluteDepth -= static_cast<uint64_t>(-RelativeDepth);
  } else {
    AbsoluteDepth += static_cast<uint64_t>(RelativeDepth);
  }
  if (AbsoluteDepth > std::numeric_limits<uint32_t>::max())
    return std::nullopt;
  return static_cast<uint32_t>(AbsoluteDepth);
}

llvm::jeandle::MonitorDepthInfo
llvm::jeandle::computeMonitorDepthInfo(Function &F) {
  MonitorDepthInfo Info;
  DenseMap<BasicBlock *, int64_t> IncomingDepth;
  SmallVector<BasicBlock *, 32> Worklist;
  SmallVector<int64_t, 8> RealExitDepths;
  int64_t MinRelativeDepth = 0;
  int64_t MaxRelativeDepth = 0;

  auto ObserveDepth = [&](int64_t Depth) {
    MinRelativeDepth = std::min(MinRelativeDepth, Depth);
    MaxRelativeDepth = std::max(MaxRelativeDepth, Depth);
  };
  auto Propagate = [&](BasicBlock *Succ, int64_t Depth) {
    auto [It, Inserted] = IncomingDepth.try_emplace(Succ, Depth);
    if (!Inserted) {
      if (It->second != Depth)
        Info.Valid = false;
      return;
    }
    Worklist.push_back(Succ);
  };
  auto RecordEnter = [&](CallBase *CB, int64_t Depth) {
    auto [It, Inserted] = Info.EnterRelativeDepth.try_emplace(CB, Depth);
    if (!Inserted && It->second != Depth)
      Info.Valid = false;
  };
  auto AdjustDepth = [&](int64_t Depth, bool IsEnter, int64_t &Adjusted) {
    if (IsEnter) {
      if (Depth == std::numeric_limits<int64_t>::max()) {
        Info.Valid = false;
        return;
      }
      Adjusted = Depth + 1;
    } else {
      if (Depth == std::numeric_limits<int64_t>::min()) {
        Info.Valid = false;
        return;
      }
      Adjusted = Depth - 1;
    }
    ObserveDepth(Adjusted);
  };

  BasicBlock *Entry = &F.getEntryBlock();
  IncomingDepth[Entry] = 0;
  Worklist.push_back(Entry);
  for (size_t Index = 0; Index != Worklist.size() && Info.Valid; ++Index) {
    BasicBlock *BB = Worklist[Index];
    int64_t Depth = IncomingDepth.lookup(BB);
    ObserveDepth(Depth);
    bool MonitorInvokeHandled = false;

    for (Instruction &I : *BB) {
      auto *CB = dyn_cast<CallBase>(&I);
      if (!CB)
        continue;
      bool IsEnter = jeandle::pea::isJeandleMonitorEnter(CB);
      bool IsExit = jeandle::pea::isJeandleMonitorExit(CB);
      if (!IsEnter && !IsExit)
        continue;

      if (isa<CallBrInst>(CB)) {
        Info.Valid = false;
        break;
      }
      if (IsEnter)
        RecordEnter(CB, Depth);
      if (!Info.Valid)
        break;

      int64_t Adjusted = Depth;
      AdjustDepth(Depth, IsEnter, Adjusted);
      if (!Info.Valid)
        break;

      if (auto *II = dyn_cast<InvokeInst>(CB)) {
        // The operation has completed only on the normal edge. The unwind
        // edge observes the depth immediately before the monitor operation.
        Propagate(II->getNormalDest(), Adjusted);
        Propagate(II->getUnwindDest(), Depth);
        MonitorInvokeHandled = true;
        break;
      }

      // A call-form monitor operation has no explicit exceptional edge, so
      // its scalar depth transition is meaningful only when it cannot unwind.
      Function *DirectCallee = CB->getCalledFunction();
      if (!CB->doesNotThrow() &&
          (!DirectCallee || !DirectCallee->doesNotThrow())) {
        Info.Valid = false;
        break;
      }
      Depth = Adjusted;
    }
    if (!Info.Valid || MonitorInvokeHandled)
      continue;

    Instruction *Term = BB->getTerminator();
    bool IsRealExit = isa<ReturnInst>(Term) || isa<ResumeInst>(Term);
    if (auto *CRI = dyn_cast<CleanupReturnInst>(Term))
      IsRealExit |= CRI->unwindsToCaller();
    if (auto *CSI = dyn_cast<CatchSwitchInst>(Term))
      IsRealExit |= CSI->unwindsToCaller();
    if (IsRealExit && !isDeoptContinuation(BB))
      RealExitDepths.push_back(Depth);
    for (BasicBlock *Succ : successors(BB))
      Propagate(Succ, Depth);
  }

  if (!Info.Valid)
    return Info;

  const bool IsOSR = F.getName().starts_with("__jeandle_osr");
  uint64_t EntryOffset = 0;
  if (!IsOSR) {
    if (MinRelativeDepth < 0)
      Info.Valid = false;
    for (int64_t ExitDepth : RealExitDepths)
      if (ExitDepth != 0)
        Info.Valid = false;
  } else if (!RealExitDepths.empty()) {
    // Every real exit must agree on the same implied entry offset
    // (-ExitDepth); a positive exit depth (more enters than exits on some
    // path) cannot be fixed by any offset and invalidates the model.
    std::optional<uint64_t> SolvedOffset;
    for (int64_t ExitDepth : RealExitDepths) {
      if (ExitDepth > 0 || ExitDepth == std::numeric_limits<int64_t>::min()) {
        Info.Valid = false;
        break;
      }
      uint64_t Candidate = static_cast<uint64_t>(-ExitDepth);
      if (!SolvedOffset)
        SolvedOffset = Candidate;
      else if (*SolvedOffset != Candidate) {
        Info.Valid = false;
        break;
      }
    }
    if (SolvedOffset)
      EntryOffset = *SolvedOffset;
  } else if (MinRelativeDepth < 0) {
    if (MinRelativeDepth == std::numeric_limits<int64_t>::min())
      Info.Valid = false;
    else
      EntryOffset = static_cast<uint64_t>(-MinRelativeDepth);
  }

  // Range validation: EntryOffset must fit the uint32_t BytecodeDepth wire
  // type, cover the deepest negative excursion, and leave headroom for the
  // deepest positive excursion. Each comparison is shaped to avoid signed
  // overflow before the widening conversion.
  constexpr uint64_t MaxLockDepth = std::numeric_limits<uint32_t>::max();
  if (MinRelativeDepth == std::numeric_limits<int64_t>::min())
    Info.Valid = false;
  if (EntryOffset > MaxLockDepth)
    Info.Valid = false;
  if (Info.Valid) {
    if (MinRelativeDepth < 0 &&
        static_cast<uint64_t>(-MinRelativeDepth) > EntryOffset)
      Info.Valid = false;
    if (MaxRelativeDepth > 0 &&
        EntryOffset + static_cast<uint64_t>(MaxRelativeDepth) > MaxLockDepth)
      Info.Valid = false;
  }
  if (Info.Valid)
    Info.EntryDepth = static_cast<uint32_t>(EntryOffset);
  return Info;
}
