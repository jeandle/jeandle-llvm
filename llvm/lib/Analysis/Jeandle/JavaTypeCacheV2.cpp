//===- JavaTypeCacheV2.cpp - Owned Java type query caches -------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Analysis/Jeandle/JavaTypeCacheV2.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/JeandleUtils.h"

using namespace llvm;
using namespace llvm::jeandle;

namespace {

constexpr unsigned MaxDependencyValues = 4096;
constexpr unsigned MaxDependencyEdges = 4 * MaxDependencyValues;

template <typename MapT, typename LeafPredicate>
size_t invalidateValues(MapT &Memo, ArrayRef<Value *> Affected,
                        bool CFGChanged, JavaTypeBaseInvalidationMode Mode,
                        size_t &SlotsScanned, LeafPredicate IsLeaf) {
  size_t OldSize = Memo.size();
  if (!CFGChanged && Mode == JavaTypeBaseInvalidationMode::SelectiveKeys) {
    for (Value *V : Affected)
      Memo.erase(V);
  } else {
    SmallPtrSet<Value *, 32> Changed(Affected.begin(), Affected.end());
    for (auto It = Memo.begin(); It != Memo.end();) {
      auto Current = It++;
      ++SlotsScanned;
      if (Changed.contains(Current->first) ||
          (CFGChanged && !IsLeaf(Current->first)))
        Memo.erase(Current);
    }
  }
  return OldSize - Memo.size();
}

} // namespace

void JavaTypeBaseCacheV2::beginQuery() {
  InitialSize = Memo.size();
  PriorKeys.clear();
  if (StatsEnabled && DetailedStats)
    for (const auto &E : Memo)
      PriorKeys.insert(E.first);
}

void JavaTypeBaseCacheV2::endQuery() {
  assert(Memo.size() >= InitialSize && "cache invalidated during query");
  if (StatsEnabled)
    Counters.EntriesAdded += Memo.size() - InitialSize;
  PriorKeys.clear();
}

void JavaTypeBaseCacheV2::recordReuse(Value *V) {
  if (StatsEnabled && DetailedStats) {
    if (PriorKeys.contains(V))
      ++Counters.PriorQueryHits;
    else
      ++Counters.CurrentQueryHits;
  }
}

void JavaTypeBaseCacheV2::recordHit(Value *V) {
  if (StatsEnabled)
    ++Counters.Hits;
  recordReuse(V);
}

void JavaTypeBaseCacheV2::recordMiss() {
  if (StatsEnabled)
    ++Counters.Misses;
}

void JavaTypeBaseCacheV2::recordNode() {
  if (StatsEnabled)
    ++Counters.NodesEvaluated;
}

void JavaTypeBaseCacheV2::recordInputHit(Value *V) {
  if (StatsEnabled) {
    ++Counters.InputHits;
    ++Counters.InputEdgesVisited;
  }
  recordReuse(V);
}

void JavaTypeBaseCacheV2::recordInputMiss() {
  if (StatsEnabled) {
    ++Counters.InputMisses;
    ++Counters.InputEdgesVisited;
  }
}

void JavaTypeBaseCacheV2::recordOpenEdge() {
  if (StatsEnabled) {
    ++Counters.OpenNodeEdges;
    ++Counters.InputEdgesVisited;
  }
}

void JavaTypeBaseCacheV2::recordCycle() {
  if (StatsEnabled)
    ++Counters.CyclicSCCs;
}

void JavaTypeBaseCacheV2::recordRefinement() {
  if (StatsEnabled)
    ++Counters.RefinementSteps;
}

void JavaTypeBaseCacheV2::clear() {
  if (StatsEnabled) {
    ++Counters.Clears;
    Counters.EntriesRemoved += Memo.size();
  }
  Memo.clear();
  PriorKeys.clear();
}

size_t JavaTypeBaseCacheV2::invalidate(ArrayRef<Value *> Affected,
                                     bool CFGChanged,
                                     JavaTypeBaseInvalidationMode Mode,
                                     size_t &SlotsScanned) {
  size_t Removed = invalidateValues(
      Memo, Affected, CFGChanged, Mode, SlotsScanned, [](Value *V) {
        // A returned-argument call is an identity expression, not a leaf.
        return isa<Argument, Constant, LoadInst>(V) ||
               (isa<CallBase>(V) && !getJavaIdentityInput(V));
      });
  if (StatsEnabled) {
    ++Counters.Invalidations;
    Counters.EntriesRemoved += Removed;
  }
  return Removed;
}

void JavaTypeDefinedCacheV2::recordHit() {
  if (StatsEnabled)
    ++Counters.Hits;
}

void JavaTypeDefinedCacheV2::recordMiss() {
  if (StatsEnabled)
    ++Counters.Misses;
}

void JavaTypeDefinedCacheV2::recordNode() {
  if (StatsEnabled)
    ++Counters.NodesEvaluated;
}

void JavaTypeDefinedCacheV2::recordInsertion(size_t Count) {
  if (StatsEnabled)
    Counters.EntriesAdded += Count;
}

void JavaTypeDefinedCacheV2::clear() {
  if (StatsEnabled) {
    ++Counters.Clears;
    Counters.EntriesRemoved += Memo.size();
  }
  Memo.clear();
}

size_t JavaTypeDefinedCacheV2::invalidate(ArrayRef<Value *> Affected,
                                        bool CFGChanged,
                                        JavaTypeBaseInvalidationMode Mode,
                                        size_t &SlotsScanned) {
  size_t Removed = invalidateValues(
      Memo, Affected, CFGChanged, Mode, SlotsScanned, [](Value *V) {
        return isa<Argument, Constant, LoadInst, CallBase, FreezeInst,
                   AllocaInst>(V);
      });
  if (StatsEnabled) {
    ++Counters.Invalidations;
    Counters.EntriesRemoved += Removed;
  }
  return Removed;
}

void JavaTypeFactsCacheV2::bind(Function &F) {
  assert((!Owner || Owner == &F) && "cache belongs to another function");
  Owner = &F;
}

void JavaTypeFactsCacheV2::recordNullRequest() {
  if (StatsEnabled)
    ++Counters.NullRequests;
}

void JavaTypeFactsCacheV2::recordNullHit() {
  if (StatsEnabled) {
    ++Counters.Hits;
    ++Counters.NullHits;
  }
}

void JavaTypeFactsCacheV2::recordNullComputed() {
  if (StatsEnabled) {
    ++Counters.Misses;
    ++Counters.NullComputed;
  }
}

void JavaTypeFactsCacheV2::recordGuardRequest() {
  if (StatsEnabled)
    ++Counters.GuardRequests;
}

void JavaTypeFactsCacheV2::recordGuardHit() {
  if (StatsEnabled) {
    ++Counters.Hits;
    ++Counters.GuardHits;
  }
}

void JavaTypeFactsCacheV2::recordGuardComputed() {
  if (StatsEnabled) {
    ++Counters.Misses;
    ++Counters.GuardComputed;
  }
}

void JavaTypeFactsCacheV2::recordGuardBypass() {
  if (StatsEnabled)
    ++Counters.GuardBypasses;
}

void JavaTypeFactsCacheV2::recordNull(bool Hit) {
  recordNullRequest();
  if (Hit)
    recordNullHit();
  else
    recordNullComputed();
}

void JavaTypeFactsCacheV2::recordGuard(bool Hit, bool Bypass) {
  recordGuardRequest();
  if (Hit)
    recordGuardHit();
  else
    recordGuardComputed();
  if (Bypass)
    recordGuardBypass();
}

void JavaTypeFactsCacheV2::recordInsertion(size_t Count) {
  if (StatsEnabled)
    Counters.EntriesAdded += Count;
}

bool JavaTypeFactsCacheV2::getNullEdge(Value *V, BasicBlock *From, BasicBlock *To,
                                     function_ref<bool()> Compute) {
  assert(Owner == From->getParent() && Owner == To->getParent() &&
         "wrong facts cache owner");
  if (CacheMode == Mode::GuardOnly) {
    recordNull(false);
    return Compute();
  }
  // Preserve the actual incoming value, including identity wrappers whose
  // oracle answers can differ from those of their underlying operands.
  Key K{V, {From, To}};
  if (auto It = NullEdges.find(K); It != NullEdges.end()) {
    recordNull(true);
    return It->second;
  }
  recordNull(false);
  bool Result = Compute();
  if (NullEdges.try_emplace(K, Result).second)
    recordInsertion();
  return Result;
}

JavaType JavaTypeFactsCacheV2::getGuard(Value *V, BasicBlock *From, BasicBlock *To,
                                      unsigned ConditionDepth,
                                      function_ref<JavaType()> Compute) {
  assert(Owner == From->getParent() && Owner == To->getParent() &&
         "wrong facts cache owner");
  // Nested condition traces must keep their original depth allowance.
  if (ConditionDepth != 0) {
    recordGuard(false, true);
    return Compute();
  }
  Key K{V, {From, To}};
  if (auto It = Guards.find(K); It != Guards.end()) {
    recordGuard(true);
    return It->second;
  }
  recordGuard(false);
  JavaType Result = Compute();
  if (Guards.try_emplace(K, Result).second)
    recordInsertion();
  return Result;
}

void JavaTypeFactsCacheV2::clear() {
  if (StatsEnabled) {
    ++Counters.Clears;
    Counters.EntriesRemoved += size();
  }
  NullEdges.clear();
  Guards.clear();
}

size_t JavaTypeFactsCacheV2::invalidate() {
  size_t Removed = size();
  if (StatsEnabled)
    ++Counters.Invalidations;
  clear();
  return Removed;
}

JavaType *JavaTypeFinalCacheV2::lookup(Value *V, BasicBlock *BB) {
  auto It = Memo.find(Key{V, BB});
  return It == Memo.end() ? nullptr : &It->second;
}

bool JavaTypeFinalCacheV2::insert(Value *V, BasicBlock *BB, const JavaType &Type) {
  bool Inserted = Memo.try_emplace(Key{V, BB}, Type).second;
  if (Inserted && StatsEnabled)
    ++Counters.EntriesAdded;
  return Inserted;
}

void JavaTypeFinalCacheV2::recordHit() {
  if (StatsEnabled)
    ++Counters.Hits;
}

void JavaTypeFinalCacheV2::recordMiss() {
  if (StatsEnabled)
    ++Counters.Misses;
}

void JavaTypeFinalCacheV2::clear() {
  if (StatsEnabled) {
    ++Counters.Clears;
    Counters.EntriesRemoved += Memo.size();
  }
  Memo.clear();
}

void JavaTypeFinalCacheV2::notifyOracleChanged() {
  invalidate();
}

size_t JavaTypeFinalCacheV2::invalidate() {
  size_t Removed = Memo.size();
  if (StatsEnabled)
    ++Counters.Invalidations;
  clear();
  return Removed;
}

void JavaTypeCacheV2::bind(Function &F) {
  assert((!Owner || Owner == &F) && "cache belongs to another function");
  Owner = &F;
  Facts.bind(F);
}

void JavaTypeCacheV2::setStatsEnabled(bool Enabled) {
  Base.setStatsEnabled(Enabled);
  Defined.setStatsEnabled(Enabled);
  Facts.setStatsEnabled(Enabled);
  Final.setStatsEnabled(Enabled);
}

void JavaTypeCacheV2::resetStats() {
  Base.resetStats();
  Defined.resetStats();
  Facts.resetStats();
  Final.resetStats();
}

void JavaTypeCacheV2::clear() {
  Base.clear();
  Defined.clear();
  Facts.clear();
  Final.clear();
}

void JavaTypeCacheV2::notifyOracleChanged() {
  Facts.invalidate();
  Final.notifyOracleChanged();
}

JavaTypeCacheV2InvalidationInfo
JavaTypeCacheV2::invalidate(ArrayRef<Value *> Changed, bool CFGChanged,
                            JavaTypeBaseInvalidationMode Mode) {
  JavaTypeCacheV2InvalidationInfo Info;
  size_t OldBase = Base.size();
  size_t OldDefined = Defined.size();
  size_t OldFacts = Facts.size();
  size_t OldFinal = Final.size();
  SmallPtrSet<Value *, 32> Seen;
  SmallVector<Value *, 32> Affected;
  SmallVector<Value *, 32> Pending(Changed.begin(), Changed.end());
  while (!Pending.empty()) {
    Value *V = Pending.pop_back_val();
    if (!V || !Seen.insert(V).second)
      continue;
    if (++Info.ValuesVisited > MaxDependencyValues) {
      Info.FullClear = true;
      break;
    }
    if (auto *BB = dyn_cast<BasicBlock>(V)) {
      if (Owner && BB->getParent() != Owner) {
        Info.FullClear = true;
        break;
      }
      // Block notifications also cover values about to be erased with a
      // block. For insertion/movement this is conservative but keeps one
      // notification contract for both block contents and their users.
      for (Instruction &I : *BB)
        Pending.push_back(&I);
      continue;
    }
    Function *ValueOwner = nullptr;
    if (auto *I = dyn_cast<Instruction>(V)) {
      ValueOwner = I->getFunction();
    } else if (auto *A = dyn_cast<Argument>(V)) {
      ValueOwner = A->getParent();
    } else {
      Info.FullClear = true;
      break;
    }
    if (Owner && ValueOwner != Owner) {
      Info.FullClear = true;
      break;
    }
    Affected.push_back(V);
    for (User *U : V->users()) {
      if (++Info.UsesVisited > MaxDependencyEdges) {
        Info.FullClear = true;
        break;
      }
      Pending.push_back(U);
    }
    if (Info.FullClear)
      break;
  }
  if (Info.FullClear) {
    if (Base.StatsEnabled)
      ++Base.Counters.Invalidations;
    if (Defined.StatsEnabled)
      ++Defined.Counters.Invalidations;
    if (Facts.StatsEnabled)
      ++Facts.Counters.Invalidations;
    if (Final.StatsEnabled)
      ++Final.Counters.Invalidations;
    clear();
    Info.BaseRemoved = OldBase;
    Info.DefinedRemoved = OldDefined;
    Info.FactsRemoved = OldFacts;
    Info.FinalRemoved = OldFinal;
    return Info;
  }
  Info.BaseRemoved =
      Base.invalidate(Affected, CFGChanged, Mode, Info.BaseSlotsScanned);
  Info.DefinedRemoved = Defined.invalidate(Affected, CFGChanged, Mode,
                                           Info.DefinedSlotsScanned);
  Info.FactsRemoved = Facts.invalidate();
  Info.FinalRemoved = Final.invalidate();
  return Info;
}
