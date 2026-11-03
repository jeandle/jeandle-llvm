//===- LVINullEdgeOracle.h - LVI-backed Java null-edge queries ---*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_ANALYSIS_JEANDLE_LVINULLEDGEORACLE_H
#define LLVM_ANALYSIS_JEANDLE_LVINULLEDGEORACLE_H

#include "llvm/ADT/DenseMap.h"
#include "llvm/Support/Compiler.h"
#include <cstdint>

namespace llvm {
class Value;
class BasicBlock;

class LazyValueInfo;

/// Optional state for exactly one top-level type query. Never reuse it after
/// IR/LVI maintenance. Omitting it preserves the original unfiltered oracle.
class LVINullEdgeQuery {
  friend struct LVINullEdgeOracle;

public:
  struct Stats {
    uint64_t Requests = 0;
    uint64_t Structural = 0;
    uint64_t Filtered = 0;
    uint64_t LVICalls = 0;
    uint64_t FilterFallbacks = 0;
  };
  explicit LVINullEdgeQuery(bool CollectStats = false)
      : CollectStats(CollectStats) {}
  const Stats &getStats() const { return Counters; }

private:
  DenseMap<Value *, bool> NeedsLVI;
  DenseMap<Value *, bool> HasTests;
  unsigned WorkRemaining = 256;
  bool LimitHit = false;
  bool CollectStats;
  Stats Counters;
  bool spendWork();
  bool hasPotentialTest(Value *V);
  bool mayNeedLVI(Value *V, unsigned Depth = 0);
};

/// A jeandle::IsNullEdgeOracle backed by LazyValueInfo: answers "is V provably
/// null on edge FromBB -> ToBB?" via LVI's edge-predicate query. The
/// referenced LVI must stay valid for the queried CFG state. After changing
/// blocks or edges, callers must update or clear LVI before the next query.
struct LVINullEdgeOracle {
  LazyValueInfo &LVI;
  LVINullEdgeQuery *Query = nullptr;
  LLVM_ABI bool operator()(Value *V, BasicBlock *FromBB, BasicBlock *ToBB) const;
};


} // namespace llvm

#endif
