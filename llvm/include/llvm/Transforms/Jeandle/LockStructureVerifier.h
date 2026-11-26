//===- LockStructureVerifier.h - Verify a coarsening candidate -*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Structural proof for an already-recognized monitor region.  This is
// deliberately local: it does not require every monitor in a function to be
// balanced, because unbalanced functions may legitimately be kept opaque and
// rejected by the transform's negative guardrails.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_LOCKSTRUCTUREVERIFIER_H
#define LLVM_TRANSFORMS_JEANDLE_LOCKSTRUCTUREVERIFIER_H

#include <string>

namespace llvm {
class DominatorTree;

namespace jeandle::lock {
struct AdjacentRegion;
class LockStackAnalysis;
struct MonitorRegion;

class LockStructureVerifier {
public:
  /// Verify the lexical straight-line shape that is specific to an adjacent
  /// candidate.  The common MonitorRegion proof is performed by the caller
  /// after the candidate has been adapted.
  bool verifyAdjacentShape(const AdjacentRegion &Region,
                           const LockStackAnalysis &Stack,
                           const DominatorTree &DT,
                           std::string *Reason = nullptr) const;

  /// Common proof for a region already discovered by either candidate search.
  /// When Stack is provided, retained exits must close a frame removed by this
  /// rewrite (or the retained enter itself), preventing a leaked inner lock.
  bool verifyBeforeRewrite(const MonitorRegion &Region,
                           const LockStackAnalysis *Stack = nullptr,
                           std::string *Reason = nullptr) const;
};

} // namespace jeandle::lock
} // namespace llvm

#endif // LLVM_TRANSFORMS_JEANDLE_LOCKSTRUCTUREVERIFIER_H
