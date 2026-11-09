//===- JeandleAnalysisUtils.h - Analysis utilities --------------*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_ANALYSIS_JEANDLE_JEANDLEANALYSISUTILS_H
#define LLVM_ANALYSIS_JEANDLE_JEANDLEANALYSISUTILS_H

namespace llvm {
class Value;
class BasicBlock;
class LazyValueInfo;

/// A jeandle::IsNullEdgeOracle backed by LazyValueInfo: answers "is V provably
/// null on edge FromBB -> ToBB?" via LVI's edge-predicate query. The
/// referenced LVI must stay valid for the queried CFG state — only passes that
/// do not mutate the CFG may hold and use this (LazyValueInfo caches per-block
/// state; splitting or erasing blocks behind its back is unsafe).
struct LVINullEdgeOracle {
  LazyValueInfo &LVI;
  bool operator()(Value *V, BasicBlock *FromBB, BasicBlock *ToBB) const;
};

} // namespace llvm

#endif
