; RUN: opt -disable-output -jeandle-java-type-stats -passes="type-check-elimination,print<java-type-analysis>,constant-field-folding,print<java-type-analysis>" -jeandle-vm-callback-log=%S/Inputs/tce.cblog %s 2>&1 | FileCheck %s --check-prefix=TCE-CFF
; RUN: opt -disable-output -jeandle-java-type-stats -passes="constant-field-folding,print<java-type-analysis>,type-check-elimination,print<java-type-analysis>" -jeandle-vm-callback-log=%S/Inputs/tce.cblog %s 2>&1 | FileCheck %s --check-prefix=CFF-TCE
; RUN: opt -disable-output -jeandle-java-type-stats -jeandle-java-type-query-trace -passes="type-check-elimination,print<java-type-analysis>,constant-field-folding,print<java-type-analysis>" -jeandle-vm-callback-log=%S/Inputs/tce.cblog %s 2>&1 | FileCheck %s --check-prefix=TRACE
;
; X02/X04: both passes query the same unknown receiver in one context block.
; Neither pass can rewrite its site, so the second query must consume the
; top-level Final entry inserted by the first.

declare ptr @jeandle.load_klass(ptr addrspace(1))
declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)

define void @tce_cff(ptr addrspace(1) nonnull %obj) #0 gc "hotspotgc" {
entry:
  %k = call ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %c = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %obj)
  ret void
}

; TCE-CFF-LABEL: JavaTypeAnalysis for function: tce_cff
; TCE-CFF:         queries: 1
; TCE-CFF:         final type misses: 1
; TCE-CFF:         base insertions: 1
; TCE-CFF-LABEL: JavaTypeAnalysis for function: tce_cff
; TCE-CFF:         queries: 2
; TCE-CFF:         final type hits: 1
; TCE-CFF:         final type misses: 1
; TCE-CFF:         base insertions: 1
; TCE-CFF:         clears: 0
; TCE-CFF:         invalidation requests: 0

; CFF-TCE-LABEL: JavaTypeAnalysis for function: tce_cff
; CFF-TCE:         queries: 1
; CFF-TCE:         final type misses: 1
; CFF-TCE:         base insertions: 1
; CFF-TCE-LABEL: JavaTypeAnalysis for function: tce_cff
; CFF-TCE:         queries: 2
; CFF-TCE:         final type hits: 1
; CFF-TCE:         final type misses: 1
; CFF-TCE:         base insertions: 1
; CFF-TCE:         clears: 0
; CFF-TCE:         invalidation requests: 0

; TRACE: JavaTypeQuery function: tce_cff ordinal: 1
; TRACE-SAME: final_hits: 0 final_misses: 1 base_insertions: 1
; TRACE: JavaTypeQuery function: tce_cff ordinal: 2
; TRACE-SAME: final_hits: 1 final_misses: 0 base_insertions: 0

attributes #0 = { "java-method"="0" }
!java-method-compilation = !{}
