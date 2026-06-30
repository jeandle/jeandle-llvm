//===- JeandleInliner.h - Jeandle method inliner ---------------*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file defines the JeandleInlineDriver and JeandleInliner passes for
// Jeandle JVM JIT. JeandleInlineDriver owns the inline pipeline shape and is
// the extension point for devirtualization refinement between inline rounds.
// JeandleInliner handles the current inline step: it inlines Java method calls
// where the callee may initially be a declaration, asks
// VMCallbacks::IsOkToInline for policy, and uses
// VMCallbacks::GetInlineCalleeIR to obtain callee IR on demand.
//
// The pass supports nested/transitive inlining: after a callee is inlined,
// newly exposed Java method call sites are considered. Inline policy, including
// any depth limit or non-root recursion decision, is decided by the VM
// callbacks. LLVM only rejects attempts to inline the root function as a
// callee, because root/caller IR and inlinee IR model unwind differently. In
// accessor-only mode, candidate callees must also carry the
// llvm::jeandle::Attribute::JavaAccessorMethod function attribute.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_JEANDLEINLINER_H
#define LLVM_TRANSFORMS_JEANDLE_JEANDLEINLINER_H

#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/IR/PassManager.h"

#include <cstdint>
#include <utility>

namespace llvm {

class Function;

using JeandleInlineScope = std::pair<Function *, int>;

struct InlineRoundResult {
  PreservedAnalyses PA = PreservedAnalyses::all();
  bool ExposedNewCallSites = false;
};

class JeandleInlineDriver : public PassInfoMixin<JeandleInlineDriver> {
public:
  explicit JeandleInlineDriver(bool InlineAccessorsOnly = false)
      : InlineAccessorsOnly(InlineAccessorsOnly) {}

  PreservedAnalyses run(Module &M, ModuleAnalysisManager &MAM);

private:
  bool InlineAccessorsOnly;
};

class JeandleInliner : public PassInfoMixin<JeandleInliner> {
public:
  explicit JeandleInliner(bool InlineAccessorsOnly = false)
      : InlineAccessorsOnly(InlineAccessorsOnly) {}

  InlineRoundResult
  runInlineRound(Module &M, ModuleAnalysisManager &MAM,
                 SmallVectorImpl<JeandleInlineScope> &InlineScopes);
  PreservedAnalyses run(Module &M, ModuleAnalysisManager &MAM);

private:
  bool InlineAccessorsOnly;
};

namespace jeandle::detail {
void clearInlineCalleeReplayState();
void materializeInlineCalleeIRForReplay(Module &M, StringRef InlineCalleeIRPath,
                                        uintptr_t CalleeMethod);
} // namespace jeandle::detail

} // namespace llvm

#endif // LLVM_TRANSFORMS_JEANDLE_JEANDLEINLINER_H
