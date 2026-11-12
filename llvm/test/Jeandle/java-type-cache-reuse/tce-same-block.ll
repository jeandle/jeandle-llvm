; RUN: opt -S -jeandle-java-type-stats -passes="type-check-elimination,print<java-type-analysis>" -jeandle-vm-callback-log=%S/Inputs/tce.cblog %s 2>&1 | FileCheck %s

; Four non-Object checks on the same unknown object in one block. TCE must
; query each site, cannot fold any check, and the final cache shares the
; repeated (Value, ContextBB) result.

declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)

define void @same_block(ptr addrspace(1) nonnull %obj) #0 gc "hotspotgc" {
entry:
  %a = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %obj)
  %b = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %obj)
  %c = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %obj)
  %d = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 9 to ptr), ptr addrspace(1) nonnull %obj)
  ret void
}

; CHECK-LABEL: JavaTypeAnalysis for function: same_block
; CHECK:         queries: 4
; CHECK:         final type hits: 3
; CHECK:         final type misses: 1
; CHECK:         base insertions: 1
; CHECK:         current base entries: 1
; CHECK:         current final type entries: 1
; CHECK:         invalidation requests: 0
; CHECK:         %a = call i1 @jeandle.check_instanceof
; CHECK:         %b = call i1 @jeandle.check_instanceof
; CHECK:         %c = call i1 @jeandle.check_instanceof
; CHECK:         %d = call i1 @jeandle.check_instanceof

attributes #0 = { "java-method"="0" }
!java-method-compilation = !{}
