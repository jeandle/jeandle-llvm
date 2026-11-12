; RUN: opt -disable-output --jeandle --jeandle-pea-iterations=0 -jeandle-java-type-stats -jeandle-java-type-query-trace -jeandle-vm-callback-log=%S/Inputs/pipeline-tce-cff.cblog %s 2>&1 | FileCheck %s
;
; X07: exercise the real Jeandle method pipeline with the PEA segment disabled
; so this test stays focused on JavaType consumers. The fixture contains the
; same TCE/CFF consumer pair as X02. This does not claim that the query pattern
; survives PEA or that the whole production pipeline is covered.

declare ptr @jeandle.load_klass(ptr addrspace(1))
declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)
declare hotspotcc void @jeandle.pre_barrier(ptr addrspace(1))
declare hotspotcc void @jeandle.post_barrier(ptr addrspace(1), ptr addrspace(1))

define void @x07_pipeline(ptr addrspace(1) nonnull %obj) #0 gc "hotspotgc" {
entry:
  %k = call ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %c = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %obj)
  ret void
}

; CHECK: JavaTypeQuery function: x07_pipeline ordinal: 1
; CHECK-SAME: final_hits: 0 final_misses: 1 base_insertions: 1
; CHECK: JavaTypeQuery function: x07_pipeline ordinal: 2
; CHECK-SAME: final_hits: 1 final_misses: 0 base_insertions: 0
; CHECK: JavaTypeQuery function: x07_pipeline ordinal: 3
; CHECK-SAME: final_hits: 0 final_misses: 1 base_insertions: 1
; CHECK: JavaTypeQuery function: x07_pipeline ordinal: 4
; CHECK-SAME: final_hits: 1 final_misses: 0 base_insertions: 0
; CHECK: JavaTypeQuery function: x07_pipeline ordinal: 5
; CHECK-SAME: final_hits: 1 final_misses: 0 base_insertions: 0
; CHECK: JavaTypeQuery function: x07_pipeline ordinal: 6
; CHECK-SAME: final_hits: 1 final_misses: 0 base_insertions: 0
; CHECK: JavaTypeQuery function: x07_pipeline ordinal: 7
; CHECK-SAME: final_hits: 1 final_misses: 0 base_insertions: 0
; CHECK-NOT: JavaTypeQuery function: x07_pipeline ordinal: 8

attributes #0 = { "java-method"="0" }
!java-method-compilation = !{}
