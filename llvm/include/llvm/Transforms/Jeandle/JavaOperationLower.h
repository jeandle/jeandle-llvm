//===- JavaOperationLower.h - Lower Java Operations -----------------------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_JAVA_OPERATION_LOWER_H
#define LLVM_JAVA_OPERATION_LOWER_H

#include "llvm/IR/PassManager.h"

namespace llvm {

class JavaOperationLower : public PassInfoMixin<JavaOperationLower> {
public:
  JavaOperationLower(int Phase) : Phase(Phase) {}

  void printPipeline(raw_ostream &OS,
                     function_ref<StringRef(StringRef)> MapClassName2PassName) {
    static_cast<PassInfoMixin<JavaOperationLower> *>(this)->printPipeline(
        OS, MapClassName2PassName);
    OS << "<phase=" << Phase << '>';
  }

  PreservedAnalyses run(Module &M, ModuleAnalysisManager &MAM);

private:
  int Phase;
};

} // namespace llvm

#endif // LLVM_JAVA_OPERATION_LOWER_H
