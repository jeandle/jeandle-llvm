; RUN: opt -disable-output -jeandle-java-type-stats -passes="type-check-elimination,print<java-type-analysis>,recover-type-info,print<java-type-analysis>" -jeandle-vm-callback-log=%S/Inputs/tce-recover.cblog %s 2>&1 | FileCheck %s --check-prefix=CROSS
; RUN: opt -disable-output -jeandle-java-type-stats -passes="type-check-elimination,print<java-type-analysis>,jeandle-java-type-cache-boundary,recover-type-info,print<java-type-analysis>" -jeandle-vm-callback-log=%S/Inputs/tce-recover.cblog %s 2>&1 | FileCheck %s --check-prefix=LOCAL
; RUN: opt -S -jeandle-java-type-stats -jeandle-java-type-query-trace -passes="type-check-elimination,print<java-type-analysis>,recover-type-info,print<java-type-analysis>" -jeandle-vm-callback-log=%S/Inputs/tce-recover.cblog %s 2>&1 | FileCheck %s --check-prefix=TRACE
;
; X03: TCE folds two checks on the same exact receiver. Its invalidation drops
; the contextual Final result but leaves the independent Base result for %obj.
; RecoverTypeInfo then re-reads the same object. CROSS-PASS therefore inserts
; Base only once; PASS-LOCAL clears the surviving Base at the boundary and
; inserts it again downstream.

declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)

define void @tce_fold_recover(ptr addrspace(1) nonnull "java-klass"="9" "java-klass-exact" %obj) #0 gc "hotspotgc" {
entry:
  %c0 = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %obj)
  %c1 = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %obj)
  %p0 = getelementptr i8, ptr addrspace(1) %obj, i64 16
  %l0 = load ptr addrspace(1), ptr addrspace(1) %p0, align 8
  %p1 = getelementptr i8, ptr addrspace(1) %obj, i64 24
  %l1 = load ptr addrspace(1), ptr addrspace(1) %p1, align 8
  ret void
}

; CROSS-LABEL: JavaTypeAnalysis for function: tce_fold_recover
; CROSS:         queries: 2
; CROSS:         final type hits: 1
; CROSS:         final type misses: 1
; CROSS:         base insertions: 1
; CROSS:         invalidation requests: 1
; CROSS:         base entries invalidated: 0
; CROSS:         final type entries invalidated: 1
; CROSS-LABEL: JavaTypeAnalysis for function: tce_fold_recover
; CROSS:         queries: 4
; CROSS:         final type hits: 2
; CROSS:         final type misses: 2
; CROSS:         base insertions: 1
; CROSS:         clears: 0

; LOCAL-LABEL: JavaTypeAnalysis for function: tce_fold_recover
; LOCAL:         queries: 2
; LOCAL:         base insertions: 1
; LOCAL:         JavaTypeCacheBoundary function: tce_fold_recover existing_analysis=1 action=clear
; LOCAL-LABEL: JavaTypeAnalysis for function: tce_fold_recover
; LOCAL:         queries: 4
; LOCAL:         final type hits: 2
; LOCAL:         final type misses: 2
; LOCAL:         base insertions: 2
; LOCAL:         clears: 1
; LOCAL:         base entries invalidated: 1
; LOCAL:         final type entries invalidated: 1

; TRACE: JavaTypeQuery function: tce_fold_recover ordinal: 1
; TRACE-SAME: final_hits: 0 final_misses: 1 base_insertions: 1
; TRACE: JavaTypeQuery function: tce_fold_recover ordinal: 2
; TRACE-SAME: final_hits: 1 final_misses: 0 base_insertions: 0
; TRACE: JavaTypeQuery function: tce_fold_recover ordinal: 3
; TRACE-SAME: final_hits: 0 final_misses: 1 base_insertions: 0
; TRACE: JavaTypeQuery function: tce_fold_recover ordinal: 4
; TRACE-SAME: final_hits: 1 final_misses: 0 base_insertions: 0

attributes #0 = { "java-method"="0" }
!java-method-compilation = !{}
