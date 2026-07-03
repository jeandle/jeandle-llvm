//===- JeandleNarrowOopMarker.h - Mark narrow oop GC roots -----*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_JEANDLENARROWOOPMARKER_H
#define LLVM_TRANSFORMS_JEANDLE_JEANDLENARROWOOPMARKER_H

#include "llvm/IR/PassManager.h"

namespace llvm {

class Module;

class JeandleNarrowOopMarker : public PassInfoMixin<JeandleNarrowOopMarker> {
public:
  PreservedAnalyses run(Module &M, ModuleAnalysisManager &AM);
};

} // namespace llvm

#endif // LLVM_TRANSFORMS_JEANDLE_JEANDLENARROWOOPMARKER_H
