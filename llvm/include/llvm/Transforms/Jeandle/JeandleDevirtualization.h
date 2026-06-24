//===- JeandleDevirtualization.h - Jeandle devirtualization ----*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_JEANDLEDEVIRTUALIZATION_H
#define LLVM_TRANSFORMS_JEANDLE_JEANDLEDEVIRTUALIZATION_H

#include "llvm/IR/PassManager.h"

namespace llvm {

class JeandleDevirtualization : public PassInfoMixin<JeandleDevirtualization> {
public:
  PreservedAnalyses runDevirtualization(Module &M, ModuleAnalysisManager &MAM);
  PreservedAnalyses run(Module &M, ModuleAnalysisManager &MAM);
};

} // namespace llvm

#endif // LLVM_TRANSFORMS_JEANDLE_JEANDLEDEVIRTUALIZATION_H
