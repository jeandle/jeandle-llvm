; RUN: opt -disable-output -jeandle-java-type-stats -jeandle-java-type-query-trace -passes="constant-field-folding,jeandle-java-type-cache-boundary,type-check-elimination,print<java-type-analysis>" -jeandle-vm-callback-log=%S/Inputs/cff-modify-tce.cblog %s 2>&1 | FileCheck %s
;
; X06: CFF folds load_klass and therefore does not preserve JavaTypeAnalysis.
; The boundary must report existing_analysis=0, and TCE must start a cold
; analysis rather than consume CFF's cache.

declare ptr @jeandle.load_klass(ptr addrspace(1))
declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)

define void @cff_modify_tce(ptr addrspace(1) nonnull "java-klass"="123" "java-klass-exact" %obj) #0 gc "hotspotgc" {
entry:
  %k = call ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %c = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 123 to ptr), ptr addrspace(1) nonnull %obj)
  ret void
}

; CHECK: JavaTypeQuery function: cff_modify_tce ordinal: 1
; CHECK-SAME: final_hits: 0 final_misses: 1 base_insertions: 1
; CHECK: JavaTypeCacheBoundary function: cff_modify_tce existing_analysis=0 action=none
; CHECK: JavaTypeQuery function: cff_modify_tce ordinal: 2
; CHECK-SAME: final_hits: 0 final_misses: 1 base_insertions: 1
; CHECK-LABEL: JavaTypeAnalysis for function: cff_modify_tce
; CHECK:         queries: 2
; CHECK:         final type hits: 0
; CHECK:         final type misses: 2
; CHECK:         base insertions: 2
; CHECK:         invalidation requests: 2
; CHECK:         CFG invalidations: 0

attributes #0 = { "java-method"="0" }
!java-method-compilation = !{}
