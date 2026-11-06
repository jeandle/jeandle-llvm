//===- JavaTypeCache.h - Owned Java type query caches ---------*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_ANALYSIS_JEANDLE_JAVATYPECACHE_H
#define LLVM_ANALYSIS_JEANDLE_JAVATYPECACHE_H

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/Jeandle/JavaType.h"
#include <cstddef>
#include <cstdint>
#include <utility>

namespace llvm {
class Function;
}

namespace llvm::jeandle {

using JavaTypeBaseMemo = DenseMap<Value *, JavaType>;
using JavaTypeDefinedMemo = DenseMap<Value *, bool>;

/// Counters belong to the cache being observed and survive clear(). They are
/// disabled by default; enable them before the measured queries/notifications.
struct JavaTypeCacheStats {
  uint64_t Hits = 0;
  uint64_t Misses = 0;
  uint64_t EntriesAdded = 0;
  uint64_t EntriesRemoved = 0;
  uint64_t Invalidations = 0;
  uint64_t Clears = 0;
};

enum class JavaTypeBaseInvalidationMode {
  SelectiveKeys,
  Scan,
};

/// Work performed by one invalidation. Counts are entries, not bytes.
struct JavaTypeCacheInvalidationInfo {
  size_t BaseRemoved = 0;
  size_t DefinedRemoved = 0;
  size_t FactsRemoved = 0;
  size_t FinalRemoved = 0;
  size_t ValuesVisited = 0;
  size_t UsesVisited = 0;
  size_t BaseSlotsScanned = 0;
  size_t DefinedSlotsScanned = 0;
  size_t PathFactsSlotsScanned = 0;
  size_t FinalTypesSlotsScanned = 0;
  bool FullClear = false;
};

/// Completed context-independent bounds. The solver also uses this storage
/// while closing an SCC: never invalidate or evict during a running query.
class LLVM_ABI JavaTypeBaseCache {
public:
  struct Stats : JavaTypeCacheStats {
    uint64_t InputHits = 0;
    uint64_t InputMisses = 0;
    uint64_t PriorQueryHits = 0;
    uint64_t CurrentQueryHits = 0;
    uint64_t NodesEvaluated = 0;
    uint64_t InputEdgesVisited = 0;
    uint64_t OpenNodeEdges = 0;
    uint64_t CyclicSCCs = 0;
    uint64_t RefinementSteps = 0;
  };

private:
  friend class JavaTypeCache;
  JavaTypeBaseMemo Memo;
  Stats Counters;
  bool StatsEnabled = false;
  bool DetailedStats = false;
  SmallPtrSet<Value *, 32> PriorKeys;
  size_t InitialSize = 0;

  void recordReuse(Value *V);

public:
  JavaTypeBaseMemo &storage() { return Memo; }
  size_t size() const { return Memo.size(); }
  const Stats &getStats() const { return Counters; }
  void resetStats() { Counters = {}; }
  void setStatsEnabled(bool Enabled) { StatsEnabled = Enabled; }
  void enableDetailedStats(bool Enabled) { DetailedStats = Enabled; }
  void beginQuery();
  void endQuery();
  void recordHit(Value *V);
  void recordMiss();
  void recordNode();
  void recordInputHit(Value *V);
  void recordInputMiss();
  void recordOpenEdge();
  void recordCycle();
  void recordRefinement();
  void clear();

  /// Affected is the complete old SSA user closure collected by the owner.
  size_t invalidate(ArrayRef<Value *> Affected, bool CFGChanged,
                    JavaTypeBaseInvalidationMode Mode, size_t &SlotsScanned);
};

/// Completed context-independent definedness proofs, including negative proofs
/// ("not proven defined"). No worklist or unfinished proof survives a query.
class LLVM_ABI JavaTypeDefinedCache {
public:
  struct Stats : JavaTypeCacheStats {
    uint64_t NodesEvaluated = 0;
  };

private:
  friend class JavaTypeCache;
  JavaTypeDefinedMemo Memo;
  Stats Counters;
  bool StatsEnabled = false;

public:
  JavaTypeDefinedMemo &storage() { return Memo; }
  size_t size() const { return Memo.size(); }
  const Stats &getStats() const { return Counters; }
  void resetStats() { Counters = {}; }
  void setStatsEnabled(bool Enabled) { StatsEnabled = Enabled; }
  void recordHit();
  void recordMiss();
  void recordNode();
  void recordInsertion(size_t Count = 1);
  void clear();
  size_t invalidate(ArrayRef<Value *> Affected, bool CFGChanged,
                    JavaTypeBaseInvalidationMode Mode, size_t &SlotsScanned);
};

/// Complete path facts during a stable oracle epoch, with edge caches for
/// queries that do not share paths. Truncated path results stay query-local.
/// Invalidation is deliberately separate from Base and Defined.
class LLVM_ABI JavaTypeFactsCache {
public:
  enum class Mode { GuardOnly, StableOracleEpoch };
  using Key = std::pair<Value *, std::pair<BasicBlock *, BasicBlock *>>;
  struct Stats : JavaTypeCacheStats {
    uint64_t PathHits = 0;
    uint64_t PathMisses = 0;
    uint64_t NullRequests = 0;
    uint64_t NullHits = 0;
    uint64_t NullComputed = 0;
    uint64_t GuardRequests = 0;
    uint64_t GuardHits = 0;
    uint64_t GuardComputed = 0;
    uint64_t GuardBypasses = 0;
  };

private:
  friend class JavaTypeCache;
  Function *Owner;
  Mode CacheMode;
  DenseMap<Key, bool> NullEdges;
  DenseMap<Key, JavaType> Guards;
  DenseMap<std::pair<Value *, BasicBlock *>, JavaType> Paths;
  Stats Counters;
  bool StatsEnabled = false;

public:
  explicit JavaTypeFactsCache(Function *F = nullptr,
                              Mode M = Mode::GuardOnly)
      : Owner(F), CacheMode(M) {}
  explicit JavaTypeFactsCache(Function &F, Mode M = Mode::GuardOnly)
      : JavaTypeFactsCache(&F, M) {}
  void bind(Function &F);
  Function *getFunction() const { return Owner; }
  Mode getMode() const { return CacheMode; }
  auto &nullStorage() { return NullEdges; }
  auto &guardStorage() { return Guards; }
  size_t nullSize() const { return NullEdges.size(); }
  size_t guardSize() const { return Guards.size(); }
  size_t pathSize() const { return Paths.size(); }
  size_t size() const { return nullSize() + guardSize() + pathSize(); }
  JavaType *lookupPath(Value *V, BasicBlock *BB);
  void insertPath(Value *V, BasicBlock *BB, const JavaType &Type);
  const Stats &getStats() const { return Counters; }
  void resetStats() { Counters = {}; }
  void setStatsEnabled(bool Enabled) { StatsEnabled = Enabled; }
  void recordNullRequest();
  void recordNullHit();
  void recordNullComputed();
  void recordGuardRequest();
  void recordGuardHit();
  void recordGuardComputed();
  void recordGuardBypass();
  void recordNull(bool Hit);
  void recordGuard(bool Hit, bool Bypass = false);
  void recordInsertion(size_t Count = 1);

  bool getNullEdge(Value *V, BasicBlock *From, BasicBlock *To,
                   function_ref<bool()> Compute);
  JavaType getGuard(Value *V, BasicBlock *From, BasicBlock *To,
                    unsigned ConditionDepth, function_ref<JavaType()> Compute);

  void clear();
  size_t invalidate();
};

/// A completed top-level query only, keyed by value and context block. Query
/// budgets limit solving work, not reuse of a valid result. Recursive facts/value
/// results never enter this cache. IR and oracle notifications clear the entire
/// table, so publication needs no dependency tracking or later revalidation.
class LLVM_ABI JavaTypeFinalCache {
public:
  using Key = std::pair<Value *, BasicBlock *>;
  using Stats = JavaTypeCacheStats;

private:
  friend class JavaTypeCache;
  DenseMap<Key, JavaType> Memo;

  Stats Counters;
  bool StatsEnabled = false;

public:
  size_t size() const { return Memo.size(); }

  const Stats &getStats() const { return Counters; }
  void resetStats() { Counters = {}; }
  void setStatsEnabled(bool Enabled) { StatsEnabled = Enabled; }
  void recordHit();
  void recordMiss();

  JavaType *lookup(Value *V, BasicBlock *BB);
  bool insert(Value *V, BasicBlock *BB, const JavaType &Type);
  void clear();
  void notifyOracleChanged();
  size_t invalidate();
};

/// Function-owned aggregate; each kind of cache keeps its own memo, counters
/// and invalidation policy. All notifications precede mutation/RAUW/deletion.
/// Also notify destination blocks before insertion/movement. CFG changes must
/// set CFGChanged; unknown changes and VM/type-universe changes require clear.
/// Oracle maintenance requires notifyOracleChanged(), even without IR changes.
/// A StableOracleEpoch permits skipping repeat oracle calls between such
/// notifications; arbitrary changing callbacks must use GuardOnly.
/// Preserved is a caller proof: unchanged CFG, guards, assumptions, type
/// metadata and oracle answers for unaffected values, including bounded-solver
/// precision. No oracle reset may occur between notification and the query.
/// Arbitrary callbacks and unknown edits must use Invalidate.
enum class JavaTypeContextPreservation { Invalidate, Preserved };

class LLVM_ABI JavaTypeCache {
  Function *Owner;
  bool EnableFinal;
  bool EnablePaths = true;

public:
  using Mode = JavaTypeFactsCache::Mode;
  JavaTypeBaseCache Base;
  JavaTypeDefinedCache Defined;
  JavaTypeFactsCache Facts;
  JavaTypeFinalCache Final;

  explicit JavaTypeCache(Function *F = nullptr, Mode M = Mode::GuardOnly,
                           bool EnableFinal = true)
      : Owner(F), EnableFinal(EnableFinal), Facts(F, M) {}
  explicit JavaTypeCache(Function &F, Mode M = Mode::GuardOnly,
                           bool EnableFinal = true)
      : JavaTypeCache(&F, M, EnableFinal) {}
  void bind(Function &F);
  Function *getFunction() const { return Owner; }
  Mode getMode() const { return Facts.getMode(); }
  void setFinalEnabled(bool Enabled) { EnableFinal = Enabled; }
  void setPathEnabled(bool Enabled) { EnablePaths = Enabled; }
  bool pathsEnabled() const {
    return EnablePaths && getMode() == Mode::StableOracleEpoch;
  }
  bool finalEnabled() const {
    return EnableFinal && getMode() == Mode::StableOracleEpoch;
  }
  void setStatsEnabled(bool Enabled);
  void setDetailedStatsEnabled(bool Enabled) {
    Base.enableDetailedStats(Enabled);
  }
  void resetStats();
  void clear();
  void notifyOracleChanged();
  size_t baseSize() const { return Base.size(); }
  size_t definedSize() const { return Defined.size(); }
  size_t pathFactsSize() const { return Facts.size(); }
  size_t finalTypesSize() const { return Final.size(); }
  JavaTypeCacheInvalidationInfo
  invalidate(ArrayRef<Value *> Changed, bool CFGChanged = false,
             JavaTypeBaseInvalidationMode Mode =
                 JavaTypeBaseInvalidationMode::SelectiveKeys,
             JavaTypeContextPreservation Context =
                 JavaTypeContextPreservation::Invalidate);
};

} // namespace llvm::jeandle

#endif // LLVM_ANALYSIS_JEANDLE_JAVATYPECACHE_H
