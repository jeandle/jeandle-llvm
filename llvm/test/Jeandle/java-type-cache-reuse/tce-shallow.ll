; RUN: opt -S -jeandle-java-type-stats -passes="type-check-elimination,print<java-type-analysis>" -jeandle-vm-callback-log=%S/Inputs/tce.cblog %s 2>&1 | FileCheck %s

; Four sibling blocks query the same base in different context blocks. Final
; results cannot be shared, but the independent base entry is reused.

declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)

define void @shallow(ptr addrspace(1) nonnull %obj, i32 %sel) #0 gc "hotspotgc" {
entry:
  switch i32 %sel, label %join [ i32 0, label %b0
                               i32 1, label %b1
                               i32 2, label %b2
                               i32 3, label %b3 ]
b0:
  %c0 = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %obj)
  br label %join
b1:
  %c1 = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %obj)
  br label %join
b2:
  %c2 = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %obj)
  br label %join
b3:
  %c3 = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %obj)
  br label %join
join:
  ret void
}

; CHECK-LABEL: JavaTypeAnalysis for function: shallow
; CHECK:         queries: 4
; One path lookup and two direct edge computations per query.
; CHECK:         edge facts misses: 12
; CHECK:         guard edge computations: 4
; CHECK:         null edge computations: 4
; CHECK:         final type hits: 0
; CHECK:         final type misses: 4
; CHECK:         base insertions: 1
; CHECK:         current base entries: 1
; CHECK:         current final type entries: 4

attributes #0 = { "java-method"="0" }
!java-method-compilation = !{}
