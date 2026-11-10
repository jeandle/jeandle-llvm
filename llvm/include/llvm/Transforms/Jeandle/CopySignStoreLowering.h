//===- CopySignStoreLowering.h - Lower copySign stores --------*- C++ -*-===//
//
// Copyright (c) 2026, The Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_COPYSIGNSTORELOWERING_H
#define LLVM_TRANSFORMS_JEANDLE_COPYSIGNSTORELOWERING_H

#include "llvm/IR/PassManager.h"

namespace llvm {

/// Lower scalar copySign store values on x86, allowing deopt-state uses.
class CopySignStoreLoweringPass
    : public PassInfoMixin<CopySignStoreLoweringPass> {
public:
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM);
};

} // namespace llvm

#endif // LLVM_TRANSFORMS_JEANDLE_COPYSIGNSTORELOWERING_H
