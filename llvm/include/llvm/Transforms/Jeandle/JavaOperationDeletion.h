//===- JavaOperationDeletion.h - Erase lowered JavaOps --------------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This pass erases JavaOp functions (those carrying the "lower-phase" function
// attribute) once they have been fully lowered by JavaOperationLower and no
// longer have any users. Deletion is split out of JavaOperationLower so that
// JavaOp definitions remain alive in the module across the inline driver and
// the O3 pipeline, which can still resolve JavaOps referenced by replayed
// inline-callee bodies by name. This pass runs once, late, after the final
// JavaOperationLower phase.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_JEANDLE_JAVA_OP_DELETION_H
#define LLVM_JEANDLE_JAVA_OP_DELETION_H

#include "llvm/IR/PassManager.h"

namespace llvm {

class JavaOperationDeletion : public PassInfoMixin<JavaOperationDeletion> {
public:
  JavaOperationDeletion() {}
  PreservedAnalyses run(Module &M, ModuleAnalysisManager &MAM);
};

} // namespace llvm

#endif // LLVM_JEANDLE_JAVA_OP_DELETION_H
