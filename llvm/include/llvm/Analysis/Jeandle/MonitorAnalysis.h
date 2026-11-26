//===- MonitorAnalysis.h - Shared Java monitor nesting analysis -*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Function-wide reconstruction of Java monitor nesting from the current LLVM
// CFG.  This is the depth model originally owned by PEA; it is shared so PEA
// and lock coarsening use the same edge-sensitive depth numbering.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_ANALYSIS_JEANDLE_MONITORANALYSIS_H
#define LLVM_ANALYSIS_JEANDLE_MONITORANALYSIS_H

#include "llvm/ADT/DenseMap.h"
#include <cstdint>
#include <optional>

namespace llvm {
class BasicBlock;
class CallBase;
class Function;

namespace jeandle {

/// Function-wide monitor nesting reconstructed from the current LLVM CFG.
/// EnterRelativeDepth records the signed depth immediately before each
/// monitorenter.  EntryDepth is normally zero; OSR roots may infer a uniform
/// nonnegative offset for interpreter-held monitors from their real exits.
struct MonitorDepthInfo {
  bool Valid = true;
  DenseMap<CallBase *, int64_t> EnterRelativeDepth;
  uint32_t EntryDepth = 0;

  /// Absolute lock depth of an enter call site.  Returns nullopt when the
  /// model is invalid, the enter was not recorded, or the result does not fit
  /// the uint32_t wire range.
  std::optional<uint32_t> getAbsoluteLockDepth(const CallBase *Enter) const;
};

// Reconstruct the function-wide monitor nesting from the current LLVM CFG:
// assign every monitorenter a signed relative lock depth (enters +1, exits
// -1) by worklist-propagating a per-block incoming depth from the entry
// block. The model is invalidated (Valid=false) by anything the scalar
// depth numbering cannot represent:
//   * a conflicting join (two preds reach a block with different depths) or
//     two visits that assign the same monitorenter different depths;
//   * a callbr monitor operation (no well-defined edge numbering);
//   * a call-form monitor operation that may unwind: a plain call has no
//     explicit exceptional edge, so its depth transition is meaningful only
//     when the call cannot throw. An invoke-form monitor operation instead
//     propagates the adjusted depth on the normal edge and the pre-op depth
//     on the unwind edge, and stops the linear scan of the block.
// Real exits (return/resume/unwind-to-caller, excluding deopt continuations)
// collect their exit depth. For a regular compilation every real exit must
// observe depth 0 and no negative depth may occur: locks are balanced. For
// an OSR compilation the interpreter may already hold monitors at entry, so
// the relative depths are solved for a uniform nonnegative entry offset that
// makes every real exit observe depth 0; when no real exit exists, the
// deepest negative excursion bounds the entry offset from below. All offset
// arithmetic is overflow-checked against the uint32_t wire range of
// BytecodeDepth; any overflow invalidates the model. Callers treat an
// invalid model as "no depth information" and fall back conservatively.
MonitorDepthInfo computeMonitorDepthInfo(Function &F);

// True iff BB ends a compilation via deoptimization. A deopt continuation
// never returns to compiled code, so it is not a "real exit" for monitor
// depth accounting even when its terminator is a return-like instruction.
bool isDeoptContinuation(const BasicBlock *BB);

} // namespace jeandle
} // namespace llvm

#endif // LLVM_ANALYSIS_JEANDLE_MONITORANALYSIS_H
