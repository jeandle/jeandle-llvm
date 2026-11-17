; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/cache-reuse.cblog %s 2>&1 | FileCheck %s
; RUN: opt -S -verify-each -jeandle-verify-java-type-cache -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/cache-reuse.cblog %s 2>&1 | FileCheck %s --check-prefix=VERIFY
; RUN: opt -disable-output -jeandle-java-type-stats -jeandle-verify-java-type-cache -passes="function(constant-field-folding,print<java-type-analysis>)" -jeandle-vm-callback-log=%S/Inputs/cache-reuse.cblog %s 2>&1 | FileCheck %s --check-prefix=STATS
;
; ConstantFieldFolding queries Java types through the cached JavaTypeAnalysis
; engine. All four call sites below query the same receiver (%obj), and the two
; jeandle.load_klass folds delete calls, so the pass must notify the cache
; before mutating:
;
;   round 1: k0 (final miss, base insert) -> fold, invalidate (context dropped)
;            k1 (final miss, base hit)    -> fold, invalidate
;            c0 (final miss, base hit)    -> mirror unavailable, keep
;            c1 (final hit)               -> reused from c0's query
;   round 2: c0, c1 are queried again; both hit the final-type cache.
;
; The receiver's base entry survives both invalidations (it is not in any call's
; use closure), so six queries insert exactly one base entry.

declare ptr @jeandle.load_klass(ptr addrspace(1))
declare ptr addrspace(1) @jeandle.get_class(ptr addrspace(1))

define void @reuse(ptr addrspace(1) nonnull "java-klass"="123" "java-klass-exact" %obj) #0 gc "hotspotgc" {
entry:
  %k0 = call ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %k1 = call ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %c0 = call ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %c1 = call ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  ret void
}

; CHECK-LABEL: define void @reuse(
; CHECK-NOT:     @jeandle.load_klass
; CHECK:         %c0 = call ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
; CHECK-NEXT:    %c1 = call ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)

; VERIFY-LABEL: define void @reuse(
; VERIFY-NOT:     @jeandle.load_klass
; VERIFY:         %c0 = call ptr addrspace(1) @jeandle.get_class
; VERIFY-NEXT:    %c1 = call ptr addrspace(1) @jeandle.get_class

; STATS-LABEL: JavaTypeAnalysis for function: reuse
; STATS:         queries: 6
; STATS:         final type hits: 3
; STATS:         final type misses: 3
; STATS:         base insertions: 1
; STATS:         clears: 0
; STATS:         invalidation requests: 2
; STATS:         selective invalidations: 2
; STATS:         CFG invalidations: 0
; STATS:         invalidation values visited: 2
; STATS:         base entries invalidated: 0
; STATS:         final type entries invalidated: 2
; STATS:         bypasses: 0
; STATS:         verifications: 6

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
