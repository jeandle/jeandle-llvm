//===- MemoryBarrier.h - Java memory ordering semantics ----------*- C++
//-*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_IR_JEANDLE_MEMORYBARRIER_H
#define LLVM_IR_JEANDLE_MEMORYBARRIER_H

#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/IR/IRBuilder.h"
#include <cstdint>
#include <optional>

namespace llvm::jeandle {

enum class MemoryBarrierKind : uint8_t {
  LoadLoad,
  LoadStore,
  Acquire,
  StoreStore,
  Release,
  StoreLoad,
  Full,
  CPUOrder,
  AllocationInit,
  ConstructorFreeze,
  CloneSource
};

enum MemoryBarrierObligation : uint8_t {
  NoBarrierObligation = 0,
  AllocationInitObligation = 1,
  ConstructorFreezeObligation = 2,
  CloneSourceObligation = 4
};

LLVM_ABI StringRef getMemoryBarrierName(MemoryBarrierKind Kind);
LLVM_ABI std::optional<MemoryBarrierKind> getMemoryBarrierKind(StringRef Name);
LLVM_ABI uint8_t getMemoryBarrierObligation(MemoryBarrierKind Kind);
LLVM_ABI bool isMemoryBarrierCall(const CallBase *CB);
LLVM_ABI bool isObjectMemoryBarrier(const CallBase *CB);

/// Semantic calls preserve ordering and optional object ownership until PEA
/// finishes. The receiver is an ownership marker, not a memory read or escape.
LLVM_ABI CallInst *createMemoryBarrier(IRBuilder<> &B, MemoryBarrierKind Kind,
                                       Value *Receiver = nullptr);
LLVM_ABI void emitMemoryBarrier(IRBuilder<> &B, MemoryBarrierKind Kind);

/// Initialization ordering covers constructor freeze at the current strength;
/// source observation additionally needs compiler ordering before an observer.
LLVM_ABI SmallVector<MemoryBarrierKind, 2>
getReplayMemoryBarriers(uint8_t Obligations, bool HasStores);

/// Clone kinds initialize their destination regardless of allocation matching.
/// Other copies need a proven tightly-coupled new-array destination.
LLVM_ABI bool copyNeedsInitializationBarrier(const CallBase &CB);

} // namespace llvm::jeandle
#endif
