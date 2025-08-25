//===- TLSPointerRewrite.h - Add a TLS base for TLS pointers --------------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TLS_POINTER_REWRITE_H
#define LLVM_TLS_POINTER_REWRITE_H

#include "llvm/IR/PassManager.h"

namespace llvm {

class TLSPointerRewrite : public PassInfoMixin<TLSPointerRewrite> {
public:
  TLSPointerRewrite() {}
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &MAM);
};

} // namespace llvm

#endif // LLVM_TLS_POINTER_REWRITE_H
