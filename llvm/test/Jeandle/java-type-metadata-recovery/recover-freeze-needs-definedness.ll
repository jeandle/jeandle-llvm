; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-freeze-needs-definedness.cblog %s 2>&1 | FileCheck %s

; freeze of a possibly-poison reference can materialize an arbitrary oop, so
; the lattice must not forward the operand's klass through it without a
; definedness proof (same rule as JavaType's freeze handling). %field is a
; load without !noundef — storing poison to the field address and loading it
; back is legal IR, and freezing that result yields an arbitrary oop whose
; klass is unknown. The chained load from the frozen value must stay untyped.

define void @test(ptr addrspace(1) "java-klass"="5" %obj) #0 gc "hotspotgc" {
entry:
  %addr = getelementptr i8, ptr addrspace(1) %obj, i64 16
  store ptr addrspace(1) poison, ptr addrspace(1) %addr
  %field = load ptr addrspace(1), ptr addrspace(1) %addr
  %frz = freeze ptr addrspace(1) %field
  %addr2 = getelementptr i8, ptr addrspace(1) %frz, i64 16
  %field2 = load ptr addrspace(1), ptr addrspace(1) %addr2
  ret void
}

; The direct field load keeps its recovered klass; the load chain through the
; frozen value must NOT be typed (nothing between the two anchors may carry
; !java-klass on %field2).
; CHECK: %field = load ptr addrspace(1), ptr addrspace(1) %addr
; CHECK-NOT: %field2{{.*}}!java-klass
; CHECK: ![[K:[0-9]+]] = !{i64 7}

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
