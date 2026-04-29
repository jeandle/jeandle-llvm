//===- PEATransformManager.h - PEA Transform Manager ---------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_PEA_TRANSFORM_MANAGER_H
#define LLVM_TRANSFORMS_JEANDLE_PEA_TRANSFORM_MANAGER_H

#include "llvm/Transforms/Jeandle/PEA/PEATransformRecord.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/Function.h"

namespace llvm::jeandle {

class PEATransformManager {
  SmallVector<PEATransformRecord> Transforms;
  unsigned CurrentOrder = 0;

public:
  PEATransformManager() = default;

  void addTransform(const PEATransformRecord &TR);
  void applyAll(Function &F);

  size_t size() const { return Transforms.size(); }
  bool empty() const { return Transforms.empty(); }
  void clear() { Transforms.clear(); }

  unsigned nextOrder() { return CurrentOrder++; }
};

} // namespace llvm::jeandle

#endif // LLVM_TRANSFORMS_JEANDLE_PEA_TRANSFORM_MANAGER_H