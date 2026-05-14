//===- NarrowOopOpt.cpp - Optimization Narrow Oop -------------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_NARROW_OOP_OPT_H
#define LLVM_NARROW_OOP_OPT_H

#include "llvm/IR/PassManager.h"

namespace llvm {

class NarrowOopOpt : public PassInfoMixin<NarrowOopOpt> {
public:
  NarrowOopOpt() {}
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &MAM);
};

} // namespace llvm

#endif // LLVM_NARROW_OOP_OPT_H
