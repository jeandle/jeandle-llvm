; RUN: opt -S -jeandle-java-type-stats -passes="type-check-elimination,print<java-type-analysis>" -jeandle-vm-callback-log=%S/Inputs/tce.cblog %s 2>&1 | FileCheck %s

; Negative control: four unknown objects have no cache-key overlap, so every
; check is a final miss and each object inserts one base entry.

declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)

define void @zero_overlap(ptr addrspace(1) nonnull %a,
                          ptr addrspace(1) nonnull %b,
                          ptr addrspace(1) nonnull %c,
                          ptr addrspace(1) nonnull %d) #0 gc "hotspotgc" {
entry:
  %a0 = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %a)
  %b0 = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %b)
  %c0 = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %c)
  %d0 = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %d)
  ret void
}

; CHECK-LABEL: JavaTypeAnalysis for function: zero_overlap
; CHECK:         queries: 4
; CHECK:         final type hits: 0
; CHECK:         final type misses: 4
; CHECK:         base insertions: 4
; CHECK:         current base entries: 4
; CHECK:         current final type entries: 4

attributes #0 = { "java-method"="0" }
!java-method-compilation = !{}
