//===- Attributes.h - Jeandle Attributes ----------------------------------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef JEANDLE_ATTRIBUTE_H
#define JEANDLE_ATTRIBUTE_H

#include "llvm/IR/Attributes.h"

namespace llvm::jeandle {

class Attribute {
public:
  /// Function attributes attached to Jeandle-compiled functions.
  static constexpr const char *UseCompressedOops = "use-compressed-oops";

  static constexpr const char *LowerPhase = "lower-phase";

  static constexpr const char *JavaMethod = "java-method";

  static constexpr const char *JavaAccessorMethod = "java-accessor-method";

  /// Java type attributes attached to function parameters, function returns,
  /// and call/invoke returns.
  static constexpr const char *JavaKlass = "java-klass";

  static constexpr const char *JavaKlassExact = "java-klass-exact";

  /// Call-site attributes attached to CallBase instructions.
  ///
  /// Java bytecode invokes are emitted as InvokeInsts, while VM calls may use
  /// CallInsts. Both are represented by CallBase.
  static constexpr const char *StatepointID = "statepoint-id";

  static constexpr const char *StatepointNumPatchBytes =
      "statepoint-num-patch-bytes";

  /// Marks a function whose call sites carry a "deopt" operand bundle for
  /// deoptimization STATE but are NOT genuine safepoints: a leaf/alloc/lock
  /// fast path that may deopt but never actually polls / reaches a VM
  /// safepoint every invocation. Mirrors C2's
  /// AllocateNode::AbstractLockNode::UnlockNode::CallLeafNode overriding
  /// `guaranteed_safepoint()` to false. The coverage logic (loop analyze,
  /// adjacency collapse, the coverage verifier) must treat such a call as NOT
  /// covering a loop, so its surrounding polls are not deleted as redundant.
  static constexpr const char *NotGuaranteedSafepoint =
      "jeandle.not-guaranteed-safepoint";

  /// Call-site attribute attached by SafepointStripMining to the safepoint
  /// poll it relocates onto the outer back-edge of a strip-mined loop nest.
  /// The attribute identifies the nest: a loop whose parent loop's latch holds
  /// a poll carrying it is the poll-free, batch-bounded inner loop. Marking
  /// the relocated poll itself means the marker cannot outlive the coverage it
  /// certifies.
  static constexpr const char *StripMinedPoll = "jeandle.strip-mined-poll";

  /// Call-site attributes attached to java call(InvokeInsts).
  static constexpr const char *Bytecode = "bytecode";

  static constexpr const char *DeclaredHolder = "declared-holder";

  static constexpr const char *MhIntrinsicName = "mh-intrinsic-name";

  static constexpr const char *MonomorphicTarget = "monomorphic-target";

  /// Marks virtual fallback calls that must not be profile-devirtualized again.
  static constexpr const char *ProfileDevirtualizationMiss =
      "profile-devirtualization-miss";

  /// Classification attributes attached to jeandle.arraycopy call sites.
  static constexpr const char *ArrayCopyKind = "jeandle.arraycopy.kind";

  static constexpr const char *ValidatedArrayCopy =
      "jeandle.arraycopy.validated";

  static constexpr const char *ArrayCopyNegativeLengthGuard =
      "jeandle.arraycopy.negative-length-guard";

  static constexpr const char *ArrayCopyKindArrayCopy = "arraycopy";
  static constexpr const char *ArrayCopyKindCloneInst = "clone-inst";
  static constexpr const char *ArrayCopyKindCloneArray = "clone-array";
  static constexpr const char *ArrayCopyKindCloneOopArray = "clone-oop-array";
};

} // namespace llvm::jeandle

#endif // JEANDLE_ATTRIBUTE_H
