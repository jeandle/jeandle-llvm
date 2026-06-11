//===- ConstantFieldFolding.h - Fold constant Java fields -------*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_CONSTANT_FIELD_FOLDING_H
#define LLVM_CONSTANT_FIELD_FOLDING_H

#include "llvm/IR/PassManager.h"

namespace llvm {

class ConstantFieldFolding : public PassInfoMixin<ConstantFieldFolding> {
public:
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM);
};

} // namespace llvm

#endif // LLVM_CONSTANT_FIELD_FOLDING_H
