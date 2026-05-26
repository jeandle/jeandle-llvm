//===- SafepointElimination.h - Safepoint Elimination ----------*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_SAFEPOINT_ELIMINATION_H
#define LLVM_SAFEPOINT_ELIMINATION_H

#include "llvm/Analysis/LoopAnalysisManager.h"
#include "llvm/IR/PassManager.h"

namespace llvm {

class LPMUpdater;
class Loop;

/// LoopPass that strips `jeandle.safepoint_poll` calls out of the back-edge
/// path of counted loops whose trip count we can prove fits within the
/// configured budget. Driven via createFunctionToLoopPassAdaptor so that
/// LoopSimplify and LCSSA run before us, and so a future strip-mining
/// transform can register newly-created outer loops with the LPM via
/// LPMUpdater.
class SafepointElimination : public PassInfoMixin<SafepointElimination> {
public:
  SafepointElimination() = default;

  PreservedAnalyses run(Loop &L, LoopAnalysisManager &AM,
                        LoopStandardAnalysisResults &AR, LPMUpdater &U);
};

} // namespace llvm

#endif // LLVM_SAFEPOINT_ELIMINATION_H
