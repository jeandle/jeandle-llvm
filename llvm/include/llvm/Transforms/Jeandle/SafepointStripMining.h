//===- SafepointStripMining.h - Safepoint strip mining --------*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_SAFEPOINTSTRIPMINING_H
#define LLVM_TRANSFORMS_JEANDLE_SAFEPOINTSTRIPMINING_H

#include "llvm/IR/PassManager.h"

namespace llvm {

enum class SafepointStripMiningMode {
  InclusiveLoopVersioning,
  StripMining,
};

struct SafepointStripMiningOptions {
  SafepointStripMiningMode Mode = SafepointStripMiningMode::StripMining;
  bool DeferEmptyLoopDeletion = false;
};

class SafepointStripMining : public PassInfoMixin<SafepointStripMining> {
public:
  explicit SafepointStripMining(
      SafepointStripMiningMode Mode = SafepointStripMiningMode::StripMining,
      bool DeferEmptyLoopDeletion = false)
      : Mode(Mode), DeferEmptyLoopDeletion(DeferEmptyLoopDeletion) {}

  void printPipeline(raw_ostream &OS,
                     function_ref<StringRef(StringRef)> MapClassName2PassName);

  PreservedAnalyses run(Function &F, FunctionAnalysisManager &AM);

private:
  SafepointStripMiningMode Mode;
  bool DeferEmptyLoopDeletion;
};

} // namespace llvm

#endif // LLVM_TRANSFORMS_JEANDLE_SAFEPOINTSTRIPMINING_H
