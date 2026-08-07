//===- SafepointPollElimination.h - Poll elimination ----------*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_SAFEPOINTPOLLELIMINATION_H
#define LLVM_TRANSFORMS_JEANDLE_SAFEPOINTPOLLELIMINATION_H

#include "llvm/IR/PassManager.h"

namespace llvm {

enum class SafepointPollEliminationMode {
  Early,
  AfterStripMining,
  LoopDeletionPrep,
};

struct SafepointPollEliminationOptions {
  SafepointPollEliminationMode Mode = SafepointPollEliminationMode::Early;
  bool DeferEmptyLoopDeletion = false;
};

class SafepointPollElimination
    : public PassInfoMixin<SafepointPollElimination> {
public:
  explicit SafepointPollElimination(
      SafepointPollEliminationMode Mode = SafepointPollEliminationMode::Early,
      bool DeferEmptyLoopDeletion = false)
      : Mode(Mode), DeferEmptyLoopDeletion(DeferEmptyLoopDeletion) {}

  void printPipeline(raw_ostream &OS,
                     function_ref<StringRef(StringRef)> MapClassName2PassName);

  PreservedAnalyses run(Function &F, FunctionAnalysisManager &AM);

private:
  SafepointPollEliminationMode Mode;
  bool DeferEmptyLoopDeletion;
};

} // namespace llvm

#endif // LLVM_TRANSFORMS_JEANDLE_SAFEPOINTPOLLELIMINATION_H
