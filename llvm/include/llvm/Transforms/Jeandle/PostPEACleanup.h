//===- PostPEACleanup.h - Clean up compiler markers after PEA -*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This pass removes compiler-only JavaOp calls whose semantics have already
// been consumed by PartialEscapeIterative. It must run immediately after PEA:
// late enough that materialization effects no longer need the calls as
// insertion points, but before loop and scalar optimizations can be inhibited
// by the keepalive side effects in the JavaOp bodies.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_POSTPEACLEANUP_H
#define LLVM_TRANSFORMS_JEANDLE_POSTPEACLEANUP_H

#include "llvm/IR/PassManager.h"

namespace llvm {

class PostPEACleanup : public PassInfoMixin<PostPEACleanup> {
public:
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM);
};

} // namespace llvm

#endif // LLVM_TRANSFORMS_JEANDLE_POSTPEACLEANUP_H
