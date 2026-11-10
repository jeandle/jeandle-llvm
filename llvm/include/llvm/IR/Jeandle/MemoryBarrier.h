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

/// Jeandle memory barrier contract:
///
/// Frontend emission and optimization transforms use createMemoryBarrier so
/// ordering retains its semantic kind and object ownership until PEA finishes.
/// JavaOperationLower phase 1 lowers these calls through emitMemoryBarrier in
/// every function body, including JavaOps that will be inlined later. Ordinary
/// Java ordering must not bypass this protocol with raw fences, target
/// intrinsics or empty inline assembly with a memory clobber.
///
/// Ordering that belongs to a JavaOp is part of that operation's contract and
/// must survive its specialization or elimination as appropriate. Keep the
/// barrier inside the JavaOp or its lowering when possible. Initialization
/// spanning multiple operations or branches may use an explicit owner marker
/// at their common completion point; it must cover every successful path,
/// including zero-length copies. Deferring an allocator's initialization
/// barrier requires a complete initializer and a matching completion marker
/// before the object can be observed.
///
/// AllocationInit, ConstructorFreeze and CloneSource take exactly one wide-oop
/// receiver (addrspace(1)). It identifies the object carrying the obligation;
/// it is neither a memory access nor a pointer capture. All other kinds have
/// no receiver and express global ordering, such as Unsafe fences or ordering
/// after Stable writes. Eliminating a local object cannot remove such global
/// obligations. Clone source ordering is independent of destination
/// initialization, even when the destination is fully scalar replaced.
///
/// PEA may fold an object marker only for an eligible whole virtual object.
/// Its obligation is recorded at that program point and travels with object
/// state through snapshots, merges, loops, rollback and materialization.
/// Unions of pending obligations must be preserved when states merge. Real,
/// null, interior or unresolved receivers are handled conservatively by
/// retaining the marker. An object that remains virtual needs no physical
/// barrier; materialization replays pending ordering after the field stores
/// and before surviving locks or observers. Pending ordering also requires
/// replay when no stores are emitted. Only equivalent replay kind/receiver
/// pairs may be reused; global or native fences are not object replay markers.
///
/// Native GC, monitor handoff, code patching/entry and cache persistence
/// protocols retain their own fences and target instructions. Their ordering
/// must not be weakened or made removable through object virtualization.
/// Atomic and volatile accesses likewise retain their access ordering.
// The Acquire, Release, Full, CPUOrder kinds and the three object kinds have
// frontend or transform producers today (Unsafe fences, @Stable release, clone
// source ordering, allocation/copy/freeze ownership). LoadLoad, LoadStore,
// StoreStore and StoreLoad currently have no producer; they complete the C2
// MemBar taxonomy, map onto the acquire/release/seq_cst fences above during
// lowering, and stay in the protocol so a future producer needs no
// cross-repo enum change.
enum class MemoryBarrierKind : uint8_t {
  LoadLoad,
  LoadStore,
  Acquire,
  StoreStore,
  Release,
  StoreLoad,
  Full,
  /// Compiler ordering required by Jeandle, encoded as a singlethread seq_cst
  /// fence. It provides no inter-thread synchronization or publication.
  CPUOrder,
  /// Complete allocation/copy initialization, including headers and payload.
  /// The receiver is the destination; place after the initialization writes.
  AllocationInit,
  /// Constructor freeze for the original entry receiver at normal returns,
  /// before synchronized-method unlock. A null receiver retains ordering when
  /// the original receiver is unavailable, such as at an OSR entry.
  ConstructorFreeze,
  /// Source observation ordering at clone entry, before source reads. The
  /// receiver is the source, independently of the destination's lifetime.
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

/// Create a bare direct hotspotcc void call, with no operand bundles. Receiver
/// is required exactly for the three object kinds above. The declaration is
/// nounwind, willreturn and gc-leaf-function; its owner parameter
/// captures(none). Keep unknown read/write memory effects: memory(none),
/// readonly or effects restricted to the receiver would hide ordering from LLVM
/// optimizations. Hand-written template declarations must carry the same
/// contract.
LLVM_ABI CallInst *createMemoryBarrier(IRBuilder<> &B, MemoryBarrierKind Kind,
                                       Value *Receiver = nullptr);

/// Final target emission, used by JavaOperationLower phase 1 after PEA:
/// - CPUOrder and CloneSource: singlethread seq_cst fence.
/// - AllocationInit, ConstructorFreeze and StoreStore: AArch64 dmb ishst;
///   otherwise a release fence.
/// - Release: release fence.
/// - LoadLoad, LoadStore and Acquire: acquire fence.
/// - StoreLoad and Full: seq_cst fence.
/// LLVM fences use system scope unless singlethread is specified above.
LLVM_ABI void emitMemoryBarrier(IRBuilder<> &B, MemoryBarrierKind Kind);

/// Select replay ordering even for a barrier-only materialization. Replayed
/// stores or pending AllocationInit require AllocationInit, which also covers
/// ConstructorFreeze at the current strength; otherwise preserve a pending
/// ConstructorFreeze. A pending CloneSource additionally requires compiler
/// ordering after replayed initialization and before source observation.
LLVM_ABI SmallVector<MemoryBarrierKind, 2>
getReplayMemoryBarriers(uint8_t Obligations, bool HasStores);

/// Clone kinds initialize their destination regardless of allocation matching.
/// Other copies need a proven tightly-coupled new-array destination.
LLVM_ABI bool copyNeedsInitializationBarrier(const CallBase &CB);

} // namespace llvm::jeandle
#endif
