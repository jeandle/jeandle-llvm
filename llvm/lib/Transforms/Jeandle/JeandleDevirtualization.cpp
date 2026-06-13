//===- JeandleDevirtualization.cpp - Jeandle devirtualization -------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// JeandleDevirtualization has two entry points by design. run() is the
// standard LLVM pass entry point for standalone use, while
// runDevirtualization() returns DevirtualizationResult so JeandleInlineDriver
// can use it as an iterative driver step and observe whether new monomorphic
// targets were exposed.
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/JeandleDevirtualization.h"

using namespace llvm;

DevirtualizationResult
JeandleDevirtualization::runDevirtualization(Module &M,
                                             ModuleAnalysisManager &MAM) {
  DevirtualizationResult Result;
  (void)M;
  (void)MAM;

  // TODO: Run Jeandle devirtualization here after an inline round exposes new
  // call sites. The implementation may combine CHA, PGO, or other JVM-guided
  // refinements to mark newly monomorphic direct calls with
  // llvm::jeandle::Attribute::MonomorphicTarget, or to rewrite a virtual call
  // into guarded direct calls.
  //
  // Any generated or cloned CallBase must preserve:
  //   - inline-scope-id metadata from the original call site, so the next
  //     inline round can pass the correct scope ID to JVM callbacks;
  //   - the deopt bundle / BCI information used by getCallSiteBCI.
  Result.PA.preserveSet<AllAnalysesOn<Module>>();
  return Result;
}

PreservedAnalyses JeandleDevirtualization::run(Module &M,
                                               ModuleAnalysisManager &MAM) {
  return runDevirtualization(M, MAM).PA;
}
