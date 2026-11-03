//===- JavaTypeAnalysisStats.h - Java type query statistics -----*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Query statistics are split out of JavaTypeAnalysis: the analysis only
// computes types and reports events through JavaTypeQueryObserver, while this
// file owns the counters, the process-wide `-stats` data and the printer
// passes. Nothing is collected by default; enable it with
// -jeandle-java-type-stats.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_ANALYSIS_JEANDLE_JAVATYPEANALYSISSTATS_H
#define LLVM_ANALYSIS_JEANDLE_JAVATYPEANALYSISSTATS_H

#include "llvm/Analysis/Jeandle/JavaTypeAnalysis.h"
#include "llvm/IR/PassManager.h"

#include <cstddef>
#include <cstdint>

namespace llvm {

class Function;
class Module;
class raw_ostream;

namespace jeandle {

/// Returns whether statistics collection is enabled. When it is off the
/// analysis creates no observer, so the query path neither counts nor reads a
/// clock. Controlled by -jeandle-java-type-stats and off by default.
LLVM_ABI bool javaTypeStatsEnabled();

/// Per-Function cumulative query, cache and verification counters; clear() only
/// resets the cache and never these counters.
/// BaseHits/BaseMisses cover base solver entry probes, including contextual
/// queries. FactsHits/FactsMisses cover guard/null edge helpers; Final counters
/// cover complete top-level queries only. Defined counters cover definedness
/// proof entry probes. Each cache owns the source counters; this observer only
/// aggregates emitted deltas across analysis lifetimes.
/// Current*/Peak* come from the cache sizes reported by the observer, so
/// printing never has to reach into JavaTypeCache.
struct JavaTypeQueryStats {
  uint64_t Queries = 0;
  uint64_t FactsHits = 0;
  uint64_t FactsMisses = 0;
  uint64_t FinalHits = 0;
  uint64_t FinalMisses = 0;
  uint64_t BaseHits = 0;
  uint64_t BaseMisses = 0;
  uint64_t BaseInsertions = 0;
  uint64_t DefinedHits = 0;
  uint64_t DefinedMisses = 0;
  uint64_t DefinedInsertions = 0;
  uint64_t GuardHits = 0;
  uint64_t GuardMisses = 0;
  uint64_t NullHits = 0;
  uint64_t NullMisses = 0;
  uint64_t OracleCalls = 0;
  uint64_t OracleStructural = 0;
  uint64_t OracleFiltered = 0;
  uint64_t OracleLVICalls = 0;
  uint64_t OracleFilterFallbacks = 0;
  uint64_t Bypasses = 0;
  uint64_t Clears = 0;
  uint64_t Invalidations = 0;
  uint64_t SelectiveInvalidations = 0;
  uint64_t CFGInvalidations = 0;
  uint64_t InvalidationVisits = 0;
  uint64_t InvalidationUsesVisited = 0;
  uint64_t BaseSlotsScanned = 0;
  uint64_t DefinedSlotsScanned = 0;
  uint64_t PathFactsSlotsScanned = 0;
  uint64_t FinalTypesSlotsScanned = 0;
  uint64_t BaseRemoved = 0;
  uint64_t DefinedRemoved = 0;
  uint64_t FactsRemoved = 0;
  uint64_t FinalRemoved = 0;
  // Sums over invalidation events, not counts of distinct retained entries.
  uint64_t BaseRetained = 0;
  uint64_t DefinedRetained = 0;
  uint64_t FactsRetained = 0;
  uint64_t FinalRetained = 0;
  uint64_t InvalidationTimeNanoseconds = 0;
  uint64_t Verifications = 0;
  uint64_t TotalQueryTimeNanoseconds = 0;
  size_t CurrentBaseEntries = 0;
  size_t CurrentDefinedEntries = 0;
  size_t CurrentPathFactsEntries = 0;
  size_t CurrentFinalTypeEntries = 0;
  size_t PeakFactsEntries = 0;
  size_t PeakFinalEntries = 0;
  size_t PeakBaseEntries = 0;
  size_t PeakDefinedEntries = 0;
};

/// Function-level statistics leaf analysis: it only holds counters and has no
/// IR dependencies. Its result never invalidates (invalidate() always returns
/// false), so a JavaTypeAnalysisResult may safely hold a JavaTypeQueryObserver
/// reference to it for its entire lifetime.
class JavaTypeStatsAnalysis : public AnalysisInfoMixin<JavaTypeStatsAnalysis> {
  friend AnalysisInfoMixin<JavaTypeStatsAnalysis>;
  LLVM_ABI static AnalysisKey Key;

public:
  struct Result : JavaTypeQueryObserver {
    explicit Result(Function &F) : F(F) {}

    const JavaTypeQueryStats &getStats() const { return Stats; }

    LLVM_ABI void onQuery(const JavaTypeQueryEvent &Event) override;
    LLVM_ABI void
    onInvalidation(const JavaTypeInvalidationEvent &Event) override;
    LLVM_ABI void print(raw_ostream &OS) const;

    /// The counters stay valid across IR changes, matching the cumulative
    /// semantics of JavaTypeAnalysis.
    bool invalidate(Function &, const PreservedAnalyses &,
                    FunctionAnalysisManager::Invalidator &) {
      return false;
    }

  private:
    Function &F;
    JavaTypeQueryStats Stats;
  };

  LLVM_ABI Result run(Function &F, FunctionAnalysisManager &FAM);
};

/// Function-level statistics printer: prints this function's query counters and
/// current cache sizes. It starts no type query, does not modify IR and
/// preserves all analyses. Non-zero data requires -jeandle-java-type-stats.
class JavaTypeAnalysisPrinterPass
    : public PassInfoMixin<JavaTypeAnalysisPrinterPass> {
  raw_ostream &OS;

public:
  explicit JavaTypeAnalysisPrinterPass(raw_ostream &OS) : OS(OS) {}
  LLVM_ABI PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM);
  static bool isRequired() { return true; }
};

/// Diagnostic-only cache boundary hook for PASS-LOCAL/CROSS-PASS experiments.
/// It clears a JavaTypeAnalysis result only if one already exists, so it does
/// not create JavaTypeAnalysis, DT, or LVI and does not change IR or analysis
/// lifetimes. CROSS-PASS pipelines omit this pass.
class JavaTypeCacheClearPass
    : public PassInfoMixin<JavaTypeCacheClearPass> {
public:
  LLVM_ABI PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM);
  static bool isRequired() { return true; }
};

/// Module-level statistics printer: prints the process-wide cumulative counters
/// at the current module processing position. The numbers may include functions
/// and modules processed earlier; it queries no type, resets no counter and
/// does not modify IR. Non-zero data also requires -jeandle-java-type-stats.
class JavaTypeAnalysisSummaryPrinterPass
    : public PassInfoMixin<JavaTypeAnalysisSummaryPrinterPass> {
  raw_ostream &OS;

public:
  explicit JavaTypeAnalysisSummaryPrinterPass(raw_ostream &OS) : OS(OS) {}
  LLVM_ABI PreservedAnalyses run(Module &M, ModuleAnalysisManager &MAM);
  static bool isRequired() { return true; }
};

} // namespace jeandle
} // namespace llvm

#endif // LLVM_ANALYSIS_JEANDLE_JAVATYPEANALYSISSTATS_H
