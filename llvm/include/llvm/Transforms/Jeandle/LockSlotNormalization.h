//===- LockSlotNormalization.h - Retain one Java BasicLock slot -*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Mechanical lock-slot rewriting for an already-proven monitor region.  This
// module does not decide whether regions may be merged; the transform and
// LockStructureVerifier must establish that first.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_LOCKSLOTNORMALIZATION_H
#define LLVM_TRANSFORMS_JEANDLE_LOCKSLOTNORMALIZATION_H

#include "llvm/ADT/SmallVector.h"

namespace llvm {
class CallInst;
class Value;

namespace jeandle::lock {
struct MonitorRegion;

/// The slot ownership decision for a coarsened region.  The retained enter's
/// slot survives and every other BasicLock slot is rewritten to it.
struct LockSlotNormalization {
  Value *RetainedLock = nullptr;
  SmallVector<Value *, 4> DiscardedLocks;
  /// Clone of the retained exit, inserted before each early exit point.
  CallInst *ExitTemplate = nullptr;
};

LockSlotNormalization planLockSlotNormalization(const MonitorRegion &Region);

/// Rewrite every use of the discarded slots to the retained slot, erase the
/// stale lifetime markers and redundant monitor operations, and delete empty
/// discarded allocas.  The caller must have verified Region and Plan.  This
/// function is a mechanical rewrite and performs no additional validity checks.
void applyLockSlotNormalization(MonitorRegion &Region,
                                const LockSlotNormalization &Plan);

} // namespace jeandle::lock
} // namespace llvm

#endif // LLVM_TRANSFORMS_JEANDLE_LOCKSLOTNORMALIZATION_H
