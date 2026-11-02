//===- JavaTypeAnalysis.h - Cached Java type queries ------------*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_ANALYSIS_JEANDLE_JAVATYPEANALYSIS_H
#define LLVM_ANALYSIS_JEANDLE_JAVATYPEANALYSIS_H

#include "llvm/Analysis/Jeandle/CachedJavaTypeV2.h"
#include "llvm/IR/PassManager.h"

#include <cstddef>
#include <cstdint>
#include <utility>

namespace llvm {

class BasicBlock;
class DominatorTree;
class Function;
class Instruction;
class LazyValueInfo;
class Value;

namespace jeandle {

/// Hit/miss observations reported by the analysis when statistics are enabled.
struct JavaTypeQueryInfo {
  uint64_t BaseHits = 0;
  uint64_t BaseMisses = 0;
  uint64_t FactsHits = 0;
  uint64_t FactsMisses = 0;
  uint64_t FinalHits = 0;
  uint64_t FinalMisses = 0;
};

/// Optional observations of one query, only built and reported when statistics
/// are enabled. Insertions count new cache entries.
struct JavaTypeQueryEvent {
  JavaTypeQueryInfo Info;
  /// Top-level query keys. These pointers are valid while the observer runs;
  /// diagnostic consumers must not retain them across IR mutation.
  Value *QueryValue = nullptr;
  BasicBlock *Context = nullptr;
  uint64_t BaseInsertions = 0;
  uint64_t DefinedHits = 0;
  uint64_t DefinedMisses = 0;
  uint64_t DefinedInsertions = 0;
  uint64_t GuardHits = 0;
  uint64_t GuardMisses = 0;
  uint64_t NullHits = 0;
  uint64_t NullMisses = 0;
  uint64_t ElapsedNanoseconds = 0;
  size_t BaseEntries = 0;
  size_t DefinedEntries = 0;
  size_t PathFactsEntries = 0;
  size_t FinalEntries = 0;
  bool Bypassed = false;
  bool Verified = false;
};

/// Optional observations of one invalidation notification.
struct JavaTypeInvalidationEvent {
  JavaTypeCacheV2InvalidationInfo Info;
  uint64_t ElapsedNanoseconds = 0;
  size_t BaseEntries = 0;
  size_t DefinedEntries = 0;
  size_t PathFactsEntries = 0;
  size_t FinalEntries = 0;
  bool CFGChanged = false;
};

/// Observation interface for queries and invalidations, used to keep statistics,
/// timing and printing out of JavaTypeAnalysis. A Result receives at most one
/// observer, at construction time, and nullptr by default. The observer must
/// outlive the Result; JavaTypeStatsAnalysis satisfies that because its result
/// never invalidates.
class JavaTypeQueryObserver {
public:
  virtual ~JavaTypeQueryObserver() = default;
  virtual void onQuery(const JavaTypeQueryEvent &Event) = 0;
  virtual void onInvalidation(const JavaTypeInvalidationEvent &Event) = 0;
};

/// 单个 Function 的分析结果，供优化 Pass 查询 JavaType 并管理缓存失效。
/// Owns separate Base, Defined, edge Facts and top-level Final caches. Traversal
/// stacks and budgets remain local to each query. DT/LVI belong to the analysis
/// manager. Notify before IR mutation; this result clears LVI and callers must
/// update DT before querying again. External LVI maintenance without an IR
/// notification also requires clear().
/// Statistics and timing are not implemented here: queries and invalidations are
/// reported to an optional Observer, and nothing is collected by default.
class JavaTypeAnalysisResult {
public:

  LLVM_ABI JavaType getJavaType(Value *V,
                                Instruction *Context = nullptr);
  LLVM_ABI void clear();
  // Notify before RAUW/deletion so the old use graph can still be traversed.
  // Ordinary IR APIs do not call these notifications. Also include destination
  // blocks for insertion/movement; set CFGChanged for structural CFG edits.
  // Unknown changes and changes to VM type information require clear().
  LLVM_ABI void invalidate(Value &Changed);
  LLVM_ABI void invalidate(ArrayRef<Value *> Changed, bool CFGChanged = false);
  LLVM_ABI void invalidateForCFGChange(Value &Changed);

  // PassManager calls this at pass boundaries using PreservedAnalyses. It
  // decides whether to discard the whole Result, not which Values changed.
  LLVM_ABI bool invalidate(Function &F, const PreservedAnalyses &PA,
                           FunctionAnalysisManager::Invalidator &Inv);

private:

  friend class JavaTypeAnalysis;

  JavaTypeAnalysisResult(Function &F, DominatorTree &DT, LazyValueInfo &LVI,
                         JavaTypeQueryObserver *Observer)
      : F(F), DT(DT), LVI(LVI), Observer(Observer),
        Cache(F, JavaTypeFactsCacheV2::Mode::StableOracleEpoch) {
    Cache.setStatsEnabled(Observer != nullptr);
  }

  Function &F;
  DominatorTree &DT;
  LazyValueInfo &LVI;

  /// Optional observer; when nullptr the query path neither counts nor reads a
  /// clock.
  JavaTypeQueryObserver *const Observer;

  JavaTypeCacheV2 Cache;

  void invalidateImpl(ArrayRef<Value *> Changed, bool CFGChanged,
                      bool ForceFull);
};

/// FunctionAnalysisManager 的分析入口：工厂方法
class JavaTypeAnalysis : public AnalysisInfoMixin<JavaTypeAnalysis> {
  friend AnalysisInfoMixin<JavaTypeAnalysis>;
  LLVM_ABI static AnalysisKey Key;

public:
  using Result = JavaTypeAnalysisResult;
  LLVM_ABI Result run(Function &F, FunctionAnalysisManager &FAM);
};

} // namespace jeandle
} // namespace llvm

#endif // LLVM_ANALYSIS_JEANDLE_JAVATYPEANALYSIS_H
