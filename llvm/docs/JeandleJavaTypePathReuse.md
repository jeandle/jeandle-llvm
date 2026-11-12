# Accumulated JavaType path reuse

The Facts owner retains completed `(Value, BasicBlock)` path results during a
StableOracleEpoch. This uses V1-style prefix reuse for all value shapes,
including PHI incoming queries and non-entry forwarders. The shared solver's
definedness and type rules remain unchanged.

Lookup and publication follow these rules:

* After the entry/definition/unreachable seed cuts, `factsAt` checks Paths
  before its local Processed table, budget and predecessor traversal. A hit
  returns the accumulated result and skips the entire predecessor subgraph.
* No root-kind or whole-function block-count admission is required. Only newly
  expanded frames consume the existing per-query facts budget. A cached prefix
  does not spend that budget, so a warm query can be more precise than a cold
  query even with the same configured budget.
* Budget exhaustion or an uncut CFG cycle sets the query's sticky
  `FactsTruncated` flag. Subsequent completed frames stay in local Processed
  rather than entering Paths. Entries completed before truncation remain
  reusable. A complete unknown result can also be shared.
* GuardOnly mode never shares path results. IR/CFG invalidation, explicit oracle
  maintenance and clear() drop Paths together with the other Facts tables.
  Existing all-context Final invalidation is unchanged: an unrelated edit can
  change LVI's bounded reasoning, so SSA independence alone does not justify
  retaining oracle-dependent results.

When path reuse is enabled, edge guards/null decisions are computed directly;
the completed accumulated path is the reusable unit. Avoiding a redundant
second cache of every constituent edge reduces fills/clears in transformation
passes which invalidate after each query. Completed path publication removes
the redundant completed per-query slot, retaining only active recursion frames.

PathHits and PathMisses expose path reuse independently of edge counters;
path lookups also contribute to the common Facts hit/miss counters.
EntriesAdded includes paths. Direct edge computations remain counted.
`setPathEnabled(false)` retains the edge-cache path for tests and ablation;
GuardOnly also continues to use edge guards without retaining null decisions.
Traversal stacks, active Processed frames and budgets remain query-local.
