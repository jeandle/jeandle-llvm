//===-- PartialEscapeAnalysis.h - PEA (analysis pass) ----------*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===---------------------------------------------------------------------===//

#ifndef LLVM_ANALYSIS_JEANDLE_PARTIALESCAPEANALYSIS_H
#define LLVM_ANALYSIS_JEANDLE_PARTIALESCAPEANALYSIS_H

#include "llvm/Analysis/Jeandle/PartialEscape.h"
#include "llvm/Jeandle/Pipeline.h"
#include "llvm/IR/PassManager.h"

namespace llvm {

class PartialEscapeAnalysis : public AnalysisInfoMixin<PartialEscapeAnalysis> {
  friend AnalysisInfoMixin<PartialEscapeAnalysis>;
  static AnalysisKey Key;

public:
  using Result = jeandle::PEAResult;
  explicit PartialEscapeAnalysis(jeandle::PartialEscapeOptions Options = {})
      : Options(Options) {}

  Result run(Function &F, FunctionAnalysisManager &FAM);

private:
  jeandle::PartialEscapeOptions Options;
};

} // namespace llvm

#endif
