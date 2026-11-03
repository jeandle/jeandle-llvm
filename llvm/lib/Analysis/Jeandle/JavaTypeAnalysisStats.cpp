//===- JavaTypeAnalysisStats.cpp - Java type query statistics -------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Analysis/Jeandle/JavaTypeAnalysisStats.h"
#include "llvm/ADT/Statistic.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Format.h"
#include "llvm/Support/raw_ostream.h"

#include <algorithm>

#define DEBUG_TYPE "java-type-analysis"

using namespace llvm;
using namespace llvm::jeandle;

namespace {

cl::opt<bool> CollectJavaTypeStats(
    "jeandle-java-type-stats",
    cl::desc("Collect Java type query and cache statistics"),
    cl::Hidden, cl::init(false));

cl::opt<bool> TraceJavaTypeQueries(
    "jeandle-java-type-query-trace",
    cl::desc("Print one diagnostic line per Java type query"),
    cl::Hidden, cl::init(false));

ALWAYS_ENABLED_STATISTIC(TotalInvalidations, "Java type invalidation requests");
ALWAYS_ENABLED_STATISTIC(TotalSelectiveInvalidations, "Java type selective invalidations");
ALWAYS_ENABLED_STATISTIC(TotalCFGInvalidations, "Java type CFG invalidations");
ALWAYS_ENABLED_STATISTIC(TotalInvalidationVisits, "Java type invalidation values visited");
ALWAYS_ENABLED_STATISTIC(TotalInvalidationUsesVisited, "Java type invalidation uses visited");
ALWAYS_ENABLED_STATISTIC(TotalBaseSlotsScanned, "Java type invalidation base slots scanned");
ALWAYS_ENABLED_STATISTIC(TotalPathFactsSlotsScanned, "Java type invalidation edge-facts slots scanned");
ALWAYS_ENABLED_STATISTIC(TotalFinalTypesSlotsScanned, "Java type invalidation final-type slots scanned");
ALWAYS_ENABLED_STATISTIC(TotalDefinedHits, "Java type definedness cache hits");
ALWAYS_ENABLED_STATISTIC(TotalDefinedMisses, "Java type definedness cache misses");
ALWAYS_ENABLED_STATISTIC(TotalDefinedInsertions, "Java type definedness cache insertions");
ALWAYS_ENABLED_STATISTIC(TotalDefinedRemoved, "Java type definedness entries invalidated");
ALWAYS_ENABLED_STATISTIC(TotalDefinedRetained, "Java type definedness entries retained");
ALWAYS_ENABLED_STATISTIC(TotalDefinedSlotsScanned, "Java type invalidation definedness slots scanned");
ALWAYS_ENABLED_STATISTIC(TotalGuardHits, "Java type guard edge cache hits");
ALWAYS_ENABLED_STATISTIC(TotalGuardMisses, "Java type guard edge computations");
ALWAYS_ENABLED_STATISTIC(TotalNullHits, "Java type null edge cache hits");
ALWAYS_ENABLED_STATISTIC(TotalNullMisses, "Java type null edge computations");
ALWAYS_ENABLED_STATISTIC(TotalOracleCalls, "Java type OracleCalls");
ALWAYS_ENABLED_STATISTIC(TotalOracleStructural, "Java type OracleStructural");
ALWAYS_ENABLED_STATISTIC(TotalOracleFiltered, "Java type OracleFiltered");
ALWAYS_ENABLED_STATISTIC(TotalOracleLVICalls, "Java type OracleLVICalls");
ALWAYS_ENABLED_STATISTIC(TotalOracleFilterFallbacks,
                         "Java type OracleFilterFallbacks");
ALWAYS_ENABLED_STATISTIC(TotalBaseRemoved, "Java type base entries invalidated");
ALWAYS_ENABLED_STATISTIC(TotalFactsRemoved, "Java type edge facts entries invalidated");
ALWAYS_ENABLED_STATISTIC(TotalFinalRemoved, "Java type final type entries invalidated");
ALWAYS_ENABLED_STATISTIC(TotalBaseRetained, "Java type base entries retained");
ALWAYS_ENABLED_STATISTIC(TotalFactsRetained, "Java type edge facts entries retained");
ALWAYS_ENABLED_STATISTIC(TotalFinalRetained, "Java type final type entries retained");
ALWAYS_ENABLED_STATISTIC(TotalInvalidationTimeNanoseconds, "Java type total invalidation time (ns)");
ALWAYS_ENABLED_STATISTIC(TotalQueryTimeNanoseconds, "Java type total query time (ns)");

ALWAYS_ENABLED_STATISTIC(TotalQueries,
                        "Java type analysis queries");
ALWAYS_ENABLED_STATISTIC(TotalFactsHits,
                        "Java type edge-facts cache hits");
ALWAYS_ENABLED_STATISTIC(TotalFactsMisses,
                        "Java type edge-facts cache misses");
ALWAYS_ENABLED_STATISTIC(TotalFinalHits,
                        "Java type final-type cache hits");
ALWAYS_ENABLED_STATISTIC(TotalFinalMisses,
                        "Java type final-type cache misses");
ALWAYS_ENABLED_STATISTIC(TotalBaseHits,
                        "Java type base query cache hits");
ALWAYS_ENABLED_STATISTIC(TotalBaseMisses,
                        "Java type base query cache misses");
ALWAYS_ENABLED_STATISTIC(TotalBaseInsertions,
                        "Java type base-cache insertions");
ALWAYS_ENABLED_STATISTIC(TotalBypasses,
                        "Java type cache bypasses");
ALWAYS_ENABLED_STATISTIC(TotalClears,
                        "Java type cache clears");
ALWAYS_ENABLED_STATISTIC(TotalVerifications,
                        "Java type cache verification queries");

/// Prints a cache hit rate; prints n/a when there is no sample yet so that we
/// never divide by zero.
void printRate(raw_ostream &OS, uint64_t Hits, uint64_t Misses) {
  if (Hits + Misses == 0) {
    OS << "n/a";
    return;
  }
  OS << format("%.2f%%", 100.0 * static_cast<double>(Hits) / static_cast<double>(Hits + Misses));
}

} // namespace

AnalysisKey JavaTypeStatsAnalysis::Key;

bool jeandle::javaTypeStatsEnabled() { return CollectJavaTypeStats; }

/// Aggregates the cache-owned counter deltas and process-wide `-stats` numbers.
/// The default query path never touches an atomic.
/// @brief accumulate one query
void JavaTypeStatsAnalysis::Result::onQuery(const JavaTypeQueryEvent &Event) {
  const JavaTypeQueryInfo &Info = Event.Info;

  const uint64_t QueryOrdinal = ++Stats.Queries;
  ++TotalQueries;

  if (TraceJavaTypeQueries) {
    errs() << "JavaTypeQuery function: " << F.getName()
           << " ordinal: " << QueryOrdinal << " value: ";
    Event.QueryValue->printAsOperand(errs(), false);
    errs() << " context: ";
    if (Event.Context)
      Event.Context->printAsOperand(errs(), false);
    else
      errs() << "<base>";
    errs() << " base_hits: " << Info.BaseHits
           << " base_misses: " << Info.BaseMisses
           << " facts_hits: " << Info.FactsHits
           << " facts_misses: " << Info.FactsMisses
           << " final_hits: " << Info.FinalHits
           << " final_misses: " << Info.FinalMisses
           << " base_insertions: " << Event.BaseInsertions
           << " defined_hits: " << Event.DefinedHits
           << " defined_misses: " << Event.DefinedMisses << '\n';
  }

  Stats.BaseHits += Info.BaseHits;
  Stats.BaseMisses += Info.BaseMisses;
  TotalBaseHits += Info.BaseHits;
  TotalBaseMisses += Info.BaseMisses;
  Stats.FactsHits += Info.FactsHits;
  Stats.FactsMisses += Info.FactsMisses;
  TotalFactsHits += Info.FactsHits;
  TotalFactsMisses += Info.FactsMisses;
  Stats.FinalHits += Info.FinalHits;
  Stats.FinalMisses += Info.FinalMisses;
  TotalFinalHits += Info.FinalHits;
  TotalFinalMisses += Info.FinalMisses;

  Stats.DefinedHits += Event.DefinedHits;
  TotalDefinedHits += Event.DefinedHits;
  Stats.DefinedMisses += Event.DefinedMisses;
  TotalDefinedMisses += Event.DefinedMisses;
  Stats.DefinedInsertions += Event.DefinedInsertions;
  TotalDefinedInsertions += Event.DefinedInsertions;
  Stats.GuardHits += Event.GuardHits;
  TotalGuardHits += Event.GuardHits;
  Stats.GuardMisses += Event.GuardMisses;
  TotalGuardMisses += Event.GuardMisses;
  Stats.NullHits += Event.NullHits;
  TotalNullHits += Event.NullHits;
  Stats.NullMisses += Event.NullMisses;
  TotalNullMisses += Event.NullMisses;
  Stats.OracleCalls += Event.OracleCalls;
  TotalOracleCalls += Event.OracleCalls;
  Stats.OracleStructural += Event.OracleStructural;
  TotalOracleStructural += Event.OracleStructural;
  Stats.OracleFiltered += Event.OracleFiltered;
  TotalOracleFiltered += Event.OracleFiltered;
  Stats.OracleLVICalls += Event.OracleLVICalls;
  TotalOracleLVICalls += Event.OracleLVICalls;
  Stats.OracleFilterFallbacks += Event.OracleFilterFallbacks;
  TotalOracleFilterFallbacks += Event.OracleFilterFallbacks;

  Stats.BaseInsertions += Event.BaseInsertions;
  TotalBaseInsertions += Event.BaseInsertions;

  Stats.CurrentBaseEntries = Event.BaseEntries;
  Stats.CurrentDefinedEntries = Event.DefinedEntries;
  Stats.CurrentPathFactsEntries = Event.PathFactsEntries;
  Stats.CurrentFinalTypeEntries = Event.FinalEntries;
  Stats.PeakBaseEntries = std::max(Stats.PeakBaseEntries, Event.BaseEntries);
  Stats.PeakDefinedEntries =
      std::max(Stats.PeakDefinedEntries, Event.DefinedEntries);
  Stats.PeakFactsEntries =
      std::max(Stats.PeakFactsEntries, Event.PathFactsEntries);
  Stats.PeakFinalEntries =
      std::max(Stats.PeakFinalEntries, Event.FinalEntries);

  if (Event.Bypassed) {
    ++Stats.Bypasses;
    ++TotalBypasses;
  }
  if (Event.Verified) {
    ++Stats.Verifications;
    ++TotalVerifications;
  }
  Stats.TotalQueryTimeNanoseconds += Event.ElapsedNanoseconds;
  TotalQueryTimeNanoseconds += Event.ElapsedNanoseconds;
}

/// @brief accumulate one invalidation notification
void JavaTypeStatsAnalysis::Result::onInvalidation(
    const JavaTypeInvalidationEvent &Event) {
  const JavaTypeCacheInvalidationInfo &Info = Event.Info;

  ++Stats.Invalidations;
  ++TotalInvalidations;
  if (Event.CFGChanged) {
    ++Stats.CFGInvalidations;
    ++TotalCFGInvalidations;
  }
  if (Info.FullClear) {
    ++Stats.Clears;
    ++TotalClears;
  } else {
    ++Stats.SelectiveInvalidations;
    ++TotalSelectiveInvalidations;
  }

  Stats.InvalidationVisits += Info.ValuesVisited;
  TotalInvalidationVisits += Info.ValuesVisited;
  Stats.InvalidationUsesVisited += Info.UsesVisited;
  TotalInvalidationUsesVisited += Info.UsesVisited;
  Stats.BaseSlotsScanned += Info.BaseSlotsScanned;
  TotalBaseSlotsScanned += Info.BaseSlotsScanned;
  Stats.PathFactsSlotsScanned += Info.PathFactsSlotsScanned;
  TotalPathFactsSlotsScanned += Info.PathFactsSlotsScanned;
  Stats.FinalTypesSlotsScanned += Info.FinalTypesSlotsScanned;
  TotalFinalTypesSlotsScanned += Info.FinalTypesSlotsScanned;
  Stats.DefinedSlotsScanned += Info.DefinedSlotsScanned;
  TotalDefinedSlotsScanned += Info.DefinedSlotsScanned;
  Stats.DefinedRemoved += Info.DefinedRemoved;
  TotalDefinedRemoved += Info.DefinedRemoved;
  Stats.BaseRemoved += Info.BaseRemoved;
  TotalBaseRemoved += Info.BaseRemoved;
  Stats.FactsRemoved += Info.FactsRemoved;
  TotalFactsRemoved += Info.FactsRemoved;
  Stats.FinalRemoved += Info.FinalRemoved;
  TotalFinalRemoved += Info.FinalRemoved;

  Stats.DefinedRetained += Event.DefinedEntries;
  TotalDefinedRetained += Event.DefinedEntries;
  Stats.BaseRetained += Event.BaseEntries;
  TotalBaseRetained += Event.BaseEntries;
  Stats.FactsRetained += Event.PathFactsEntries;
  TotalFactsRetained += Event.PathFactsEntries;
  Stats.FinalRetained += Event.FinalEntries;
  TotalFinalRetained += Event.FinalEntries;

  Stats.CurrentBaseEntries = Event.BaseEntries;
  Stats.CurrentDefinedEntries = Event.DefinedEntries;
  Stats.CurrentPathFactsEntries = Event.PathFactsEntries;
  Stats.CurrentFinalTypeEntries = Event.FinalEntries;

  Stats.InvalidationTimeNanoseconds += Event.ElapsedNanoseconds;
  TotalInvalidationTimeNanoseconds += Event.ElapsedNanoseconds;
}

/// Prints the cumulative query counters of the current Function plus the
/// current and peak sizes of all four caches. Edge helpers and top-level final
/// lookups are counted separately; base probes also include contextual queries.
void JavaTypeStatsAnalysis::Result::print(raw_ostream &OS) const {
  OS << "JavaTypeAnalysis for function: " << F.getName() << '\n';
  OS << "  queries: " << Stats.Queries << '\n';
  OS << "  edge facts hits: " << Stats.FactsHits << '\n';
  OS << "  edge facts misses: " << Stats.FactsMisses << '\n';
  OS << "  edge facts hit rate: ";
  printRate(OS, Stats.FactsHits, Stats.FactsMisses);
  OS << '\n';
  OS << "  guard edge hits: " << Stats.GuardHits << '\n';
  OS << "  guard edge computations: " << Stats.GuardMisses << '\n';
  OS << "  null edge hits: " << Stats.NullHits << '\n';
  OS << "  null edge computations: " << Stats.NullMisses << '\n';
  OS << "  null oracle requests: " << Stats.OracleCalls << '\n';
  OS << "  null oracle structural answers: " << Stats.OracleStructural << '\n';
  OS << "  null oracle filtered: " << Stats.OracleFiltered << '\n';
  OS << "  null oracle LVI calls: " << Stats.OracleLVICalls << '\n';
  OS << "  null oracle filter fallbacks: " << Stats.OracleFilterFallbacks
     << '\n';
  OS << "  final type hits: " << Stats.FinalHits << '\n';
  OS << "  final type misses: " << Stats.FinalMisses << '\n';
  OS << "  final type hit rate: ";
  printRate(OS, Stats.FinalHits, Stats.FinalMisses);
  OS << '\n';
  OS << "  base query hits: " << Stats.BaseHits << '\n';
  OS << "  base query misses: " << Stats.BaseMisses << '\n';
  OS << "  base query hit rate: ";
  printRate(OS, Stats.BaseHits, Stats.BaseMisses);
  OS << '\n';
  OS << "  defined hits: " << Stats.DefinedHits << '\n';
  OS << "  defined misses: " << Stats.DefinedMisses << '\n';
  OS << "  defined hit rate: ";
  printRate(OS, Stats.DefinedHits, Stats.DefinedMisses);
  OS << '\n';
  OS << "  defined insertions: " << Stats.DefinedInsertions << '\n';
  OS << "  current defined entries: " << Stats.CurrentDefinedEntries << '\n';
  OS << "  peak defined entries: " << Stats.PeakDefinedEntries << '\n';
  OS << "  base insertions: " << Stats.BaseInsertions << '\n';
  OS << "  current base entries: " << Stats.CurrentBaseEntries << '\n';
  OS << "  peak base entries: " << Stats.PeakBaseEntries << '\n';
  OS << "  current edge facts entries: " << Stats.CurrentPathFactsEntries << '\n';
  OS << "  peak edge facts entries: " << Stats.PeakFactsEntries << '\n';
  OS << "  current final type entries: " << Stats.CurrentFinalTypeEntries << '\n';
  OS << "  peak final type entries: " << Stats.PeakFinalEntries << '\n';
  OS << "  clears: " << Stats.Clears << '\n';
  OS << "  invalidation requests: " << Stats.Invalidations << '\n';
  OS << "  selective invalidations: " << Stats.SelectiveInvalidations << '\n';
  OS << "  CFG invalidations: " << Stats.CFGInvalidations << '\n';
  OS << "  invalidation values visited: " << Stats.InvalidationVisits << '\n';
  OS << "  invalidation uses visited: " << Stats.InvalidationUsesVisited
     << '\n';
  OS << "  invalidation base slots scanned: " << Stats.BaseSlotsScanned << '\n';
  OS << "  invalidation edge-facts slots scanned: " << Stats.PathFactsSlotsScanned
     << '\n';
  OS << "  invalidation final-type slots scanned: "
     << Stats.FinalTypesSlotsScanned << '\n';
  OS << "  invalidation defined slots scanned: " << Stats.DefinedSlotsScanned << '\n';
  OS << "  defined entries invalidated: " << Stats.DefinedRemoved << '\n';
  OS << "  defined entries retained: " << Stats.DefinedRetained << '\n';
  OS << "  base entries invalidated: " << Stats.BaseRemoved << '\n';
  OS << "  edge facts entries invalidated: " << Stats.FactsRemoved << '\n';
  OS << "  final type entries invalidated: " << Stats.FinalRemoved << '\n';
  OS << "  base entries retained: " << Stats.BaseRetained << '\n';
  OS << "  edge facts entries retained: " << Stats.FactsRetained << '\n';
  OS << "  final type entries retained: " << Stats.FinalRetained << '\n';
  OS << "  total invalidation time (ns): " << Stats.InvalidationTimeNanoseconds << '\n';
  OS << "  bypasses: " << Stats.Bypasses << '\n';
  OS << "  verifications: " << Stats.Verifications << '\n';
  OS << "  total query time (ns): " << Stats.TotalQueryTimeNanoseconds << '\n';
}

/// The result has no IR dependencies, so construction reads nothing from the
/// function.
JavaTypeStatsAnalysis::Result
JavaTypeStatsAnalysis::run(Function &F, FunctionAnalysisManager &) {
  return Result(F);
}

/// Prints the statistics of the given Function; it only observes existing
/// counters and starts no type query. It does not modify IR and therefore
/// preserves all analyses.
PreservedAnalyses
JavaTypeAnalysisPrinterPass::run(Function &F, FunctionAnalysisManager &FAM) {
  FAM.getResult<JavaTypeStatsAnalysis>(F).print(OS);
  return PreservedAnalyses::all();
}

/// Prints the process-wide cumulative counters at the module processing
/// position; the numbers include functions and modules processed earlier. It
/// resets no counter, modifies no IR and triggers no Java type query.
PreservedAnalyses
JavaTypeCacheClearPass::run(Function &F, FunctionAnalysisManager &FAM) {
  auto *Result = FAM.getCachedResult<JavaTypeAnalysis>(F);
  if (CollectJavaTypeStats)
    errs() << "JavaTypeCacheBoundary function: " << F.getName()
           << " existing_analysis=" << (Result ? 1 : 0)
           << " action=" << (Result ? "clear" : "none") << '\n';
  if (Result)
    Result->clear();
  return PreservedAnalyses::all();
}

PreservedAnalyses
JavaTypeAnalysisSummaryPrinterPass::run(Module &M, ModuleAnalysisManager &) {
  OS << "JavaTypeAnalysis process summary after module: " << M.getName() << '\n';
  OS << "  queries: " << TotalQueries.getValue() << '\n';
  OS << "  edge facts hits: " << TotalFactsHits.getValue() << '\n';
  OS << "  edge facts misses: " << TotalFactsMisses.getValue() << '\n';
  OS << "  guard edge hits: " << TotalGuardHits.getValue() << '\n';
  OS << "  guard edge computations: " << TotalGuardMisses.getValue() << '\n';
  OS << "  null edge hits: " << TotalNullHits.getValue() << '\n';
  OS << "  null edge computations: " << TotalNullMisses.getValue() << '\n';
  OS << "  null oracle requests: " << TotalOracleCalls.getValue() << '\n';
  OS << "  null oracle structural answers: " << TotalOracleStructural.getValue()
     << '\n';
  OS << "  null oracle filtered: " << TotalOracleFiltered.getValue() << '\n';
  OS << "  null oracle LVI calls: " << TotalOracleLVICalls.getValue() << '\n';
  OS << "  null oracle filter fallbacks: "
     << TotalOracleFilterFallbacks.getValue() << '\n';
  OS << "  final type hits: " << TotalFinalHits.getValue() << '\n';
  OS << "  final type misses: " << TotalFinalMisses.getValue() << '\n';
  OS << "  base query hits: " << TotalBaseHits.getValue() << '\n';
  OS << "  base query misses: " << TotalBaseMisses.getValue() << '\n';
  OS << "  defined hits: " << TotalDefinedHits.getValue() << '\n';
  OS << "  defined misses: " << TotalDefinedMisses.getValue() << '\n';
  OS << "  defined insertions: " << TotalDefinedInsertions.getValue() << '\n';
  OS << "  base insertions: " << TotalBaseInsertions.getValue() << '\n';
  OS << "  clears: " << TotalClears.getValue() << '\n';
  OS << "  invalidation requests: " << TotalInvalidations.getValue() << '\n';
  OS << "  selective invalidations: " << TotalSelectiveInvalidations.getValue() << '\n';
  OS << "  CFG invalidations: " << TotalCFGInvalidations.getValue() << '\n';
  OS << "  invalidation values visited: " << TotalInvalidationVisits.getValue() << '\n';
  OS << "  invalidation uses visited: "
     << TotalInvalidationUsesVisited.getValue() << '\n';
  OS << "  invalidation base slots scanned: " << TotalBaseSlotsScanned.getValue() << '\n';
  OS << "  invalidation edge-facts slots scanned: "
     << TotalPathFactsSlotsScanned.getValue() << '\n';
  OS << "  invalidation final-type slots scanned: "
     << TotalFinalTypesSlotsScanned.getValue() << '\n';
  OS << "  invalidation defined slots scanned: " << TotalDefinedSlotsScanned.getValue() << '\n';
  OS << "  defined entries invalidated: " << TotalDefinedRemoved.getValue() << '\n';
  OS << "  defined entries retained: " << TotalDefinedRetained.getValue() << '\n';
  OS << "  base entries invalidated: " << TotalBaseRemoved.getValue() << '\n';
  OS << "  edge facts entries invalidated: " << TotalFactsRemoved.getValue() << '\n';
  OS << "  final type entries invalidated: " << TotalFinalRemoved.getValue() << '\n';
  OS << "  base entries retained: " << TotalBaseRetained.getValue() << '\n';
  OS << "  edge facts entries retained: " << TotalFactsRetained.getValue() << '\n';
  OS << "  final type entries retained: " << TotalFinalRetained.getValue() << '\n';
  OS << "  total invalidation time (ns): " << TotalInvalidationTimeNanoseconds.getValue() << '\n';
  OS << "  total query time (ns): " << TotalQueryTimeNanoseconds.getValue() << '\n';
  OS << "  bypasses: " << TotalBypasses.getValue() << '\n';
  OS << "  verifications: " << TotalVerifications.getValue() << '\n';
  return PreservedAnalyses::all();
}
