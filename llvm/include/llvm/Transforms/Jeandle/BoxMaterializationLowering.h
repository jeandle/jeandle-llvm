//===- BoxMaterializationLowering.h - Lower surviving box JavaOps -*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_BOXMATERIALIZATIONLOWERING_H
#define LLVM_TRANSFORMS_JEANDLE_BOXMATERIALIZATIONLOWERING_H

#include "llvm/IR/PassManager.h"

namespace llvm {

// Expand only surviving jeandle.box calls after PEA. Keeping the operation
// opaque until this point lets PEA model its primitive payload, while lowering
// it before range and loop optimization exposes the ordinary valueOf cache
// check and allocation path to the rest of the optimizer.
class BoxMaterializationLowering
    : public PassInfoMixin<BoxMaterializationLowering> {
public:
  PreservedAnalyses run(Module &M, ModuleAnalysisManager &MAM);
};

} // namespace llvm

#endif // LLVM_TRANSFORMS_JEANDLE_BOXMATERIALIZATIONLOWERING_H
