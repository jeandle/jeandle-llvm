# Query-local LVI null-edge filtering

The optimization is attached to the typed LVINullEdgeOracle, not the generic
IsNullEdgeOracle callback. Existing one-argument LVINullEdgeOracle{LVI} calls
remain unfiltered. JavaTypeAnalysis creates an explicit LVINullEdgeQuery for
each top-level query, and the native benchmark follows the same API. The state
must never outlive a query or cross IR/LVI maintenance.

Before asking LVI, the filter establishes that neither uses nor definitions
can supply a null constant. It scans a bounded use closure, conservatively
following aliases, casts, zero GEPs, freezes, select/PHI users and returned
arguments. Any comparison, ptrtoint or unsupported use retains LVI. Ordinary
non-returned call arguments, memory operands and returns cannot positively
prove their operand null in LVI.

Arguments without relevant tests cannot acquire a null lattice constant.
Select/PHI definitions are filtered only when every feasible input also lacks
a null source. A single possible null arm keeps LVI; constant select conditions
inspect the selected arm. Constants, returned calls, loads, unknown definitions
and unproven freezes retain LVI. Cycles, more than 256 scan steps, or definition
depth above 64 also retain LVI. The existing freeze definedness check is unchanged.

This is deliberately more conservative than the old V1 prefilter: it does not
rely on absence of dominating direct-null comparisons alone, nor on both arms
of a select folding null. It can skip fewer queries but does not drop required
proofs in those cases. No block-level getConstant query or new oracle-call cap
is introduced. The original LVI predicate remains the fallback.

The shared facts solver also stops joining predecessors once the accumulator
is fully unknown, the absorbing element of typeUnion. Cache, cycle, budget and
IR/oracle invalidation policies remain unchanged.

Verification recomputes with the unfiltered oracle. Filter requests, structural
answers, skipped LVI calls, actual LVI calls and limit fallbacks are collected
only with an observer (or native diagnostic mode). Native diagnostics compare
complete JavaTypes using fresh DT/AC/LVI and the unfiltered engine. The switch
-jeandle-disable-null-edge-prefilter supports an ablation without disabling
normal null-edge reasoning.

Tests cover negative arguments/select chains, structural and indirect null
proofs, select/PHI fallbacks, returned aliases/integer comparisons, unsafe
freeze, scan/depth limits and a new query after IR/LVI changes.
