//===- InsertGCBarriers.h - Insert GC Barriers ----------------------------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_INSERT_GC_BARRIERS_H
#define LLVM_INSERT_GC_BARRIERS_H

#include "llvm/IR/PassManager.h"

namespace llvm {

class InsertGCBarriers : public PassInfoMixin<InsertGCBarriers> {
public:
  InsertGCBarriers() {}
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM);
};

} // namespace llvm

#endif // LLVM_INSERT_GC_BARRIERS_H
