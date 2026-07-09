//===- ExpandNarrowOopCast.h - Expand narrow oop casts -------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_EXPAND_NARROW_OOP_CAST_H
#define LLVM_EXPAND_NARROW_OOP_CAST_H

#include "llvm/IR/PassManager.h"

namespace llvm {

class ExpandNarrowOopCast : public PassInfoMixin<ExpandNarrowOopCast> {
public:
  ExpandNarrowOopCast() {}
  PreservedAnalyses run(Module &M, ModuleAnalysisManager &MAM);
};

} // namespace llvm

#endif // LLVM_EXPAND_NARROW_OOP_CAST_H
