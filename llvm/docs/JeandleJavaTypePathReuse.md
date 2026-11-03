# Budget-safe JavaType path reuse

The Facts owner additionally retains completed `(Value, BasicBlock)` path
results during a StableOracleEpoch. This restores V1-style prefix reuse for
argument queries and entry-block selects, while retaining V2's strict cold/warm
budget, PHI, definedness and oracle contracts.

Admission is deliberately conservative:

* The root must be an Argument or an entry-block SelectInst. Arguments do not
  recursively query other value facts. In valid SSA an entry-block select's
  complete operand graph is in entry or consists of arguments/constants; the
  shared base solver already computes its value type. No operand definition
  point contributes CFG facts there, so the value dimension returns Base.
* The function's block count must fit the initial facts budget. A single-value
  query can expand at most one frame per block. Reusing completed prefixes
  cannot hide a budget exhaustion because a cold traversal already fits.
  The admission block count is computed once per unchanged CFG; LLVM list
  size() is linear. Oracle/non-CFG notifications preserve only this structural
  count, never cached type or oracle results. CFG changes and clear() reset it.
* Any uncut CFG cycle taints the rest of that query for publication. Previously
  completed, cycle-free subgraphs remain safe; active/cycle-cut results never
  become shared path entries. PHI and other forwarder queries retain the
  original per-query memoization and edge caches.
* GuardOnly mode never shares path results. IR/CFG invalidation, explicit oracle
  maintenance and clear() drop Paths together with the other Facts tables.
  Existing all-context Final invalidation is unchanged: an unrelated edit can
  change LVI's bounded reasoning, so SSA independence alone does not justify
  retaining oracle-dependent results.

On an admitted query, cold edge guards/null decisions are computed directly;
the completed accumulated path is the reusable unit. Avoiding a redundant
second cache of every constituent edge reduces fills/clears in transformation
passes which invalidate after each query. Completed path publication removes
the redundant completed per-query slot, retaining only active recursion frames.

PathHits and PathMisses expose path reuse independently of edge counters.
EntriesAdded includes paths. Direct cold edge computations remain counted. setPathEnabled(false) isolates edge-cache tests
and supports ablation. Existing Base/edge tests disable this upper reuse layer,
just as they already disable Final; dedicated tests exercise path reuse,
budget changes, irreducible cycles and epoch invalidation. Non-entry selects
retain operand definition-point refinement.
