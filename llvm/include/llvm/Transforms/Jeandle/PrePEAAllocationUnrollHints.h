//===- PrePEAAllocationUnrollHints.h --------------------------*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_PREPEAALLOCATIONUNROLLHINTS_H
#define LLVM_TRANSFORMS_JEANDLE_PREPEAALLOCATIONUNROLLHINTS_H

#include "llvm/IR/PassManager.h"

namespace llvm::jeandle {

// Shared trip-count cap for allocation hints and the standard full unroller.
unsigned getPrePEAFullUnrollMaxCount();

// Allow bounded full unrolling of short allocation consumers before PEA.
class PrePEAAllocationUnrollHints
    : public PassInfoMixin<PrePEAAllocationUnrollHints> {
public:
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM);
};

} // namespace llvm::jeandle

#endif
