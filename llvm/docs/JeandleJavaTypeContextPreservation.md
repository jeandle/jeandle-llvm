# Explicit context preservation

Ordinary invalidate remains conservative. A caller may opt into
JavaTypeContextPreservation::Preserved (or Analysis.invalidatePreservingContext)
only after proving that CFG, edge predicates, assumptions, type metadata and
oracle answers/precision for unaffected values are preserved. The old SSA user
closure still invalidates Base/Defined and affected context keys. CFG changes,
foreign values and invalidation limits retain conservative fallback.

Analysis keeps its LVI state on this path. Explicit oracle maintenance still
clears all context entries. Arbitrary callbacks cannot be classified by looking
at the changed instruction; callers lacking a proof must use ordinary invalidate.
A dead integer add whose only edit replaces an integer constant with another of
the same type, leaving all nonconstant operands and instruction structure fixed,
is the benchmark's opted-in case. No existing transformation automatically opts
in. This API is not a general claim that every pure instruction edit is safe.
