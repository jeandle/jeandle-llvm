; RUN: opt -S -jeandle-java-type-stats -passes="type-check-elimination,print<java-type-analysis>" -jeandle-vm-callback-log=%S/Inputs/tce.cblog %s 2>&1 | FileCheck %s
;
; P4 deep-CFG control: the same receiver is queried in four serialized context
; blocks. There is no Final sharing across blocks, but the Base entry survives;
; this isolates context depth from query count and shared DAG size. Folding the
; downstream checks clears all four Final entries while preserving the independent
; Base entry.

declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)

define void @deep_checks(ptr addrspace(1) nonnull %obj) #0 gc "hotspotgc" {
entry:
  %c0 = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %obj)
  br i1 %c0, label %b1, label %exit
b1:
  %c1 = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %obj)
  br i1 %c1, label %b2, label %exit
b2:
  %c2 = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %obj)
  br i1 %c2, label %b3, label %exit
b3:
  %c3 = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %obj)
  br label %exit
exit:
  ret void
}

; CHECK-LABEL: JavaTypeAnalysis for function: deep_checks
; CHECK:         queries: 4
; CHECK:         final type hits: 0
; CHECK:         final type misses: 4
; CHECK:         base insertions: 1
; CHECK:         current base entries: 1
; CHECK:         current final type entries: 0
; CHECK:         peak final type entries: 4
; CHECK:         invalidation requests: 1
; CHECK:         base entries invalidated: 0
; CHECK:         final type entries invalidated: 4

attributes #0 = { "java-method"="0" }
!java-method-compilation = !{}
