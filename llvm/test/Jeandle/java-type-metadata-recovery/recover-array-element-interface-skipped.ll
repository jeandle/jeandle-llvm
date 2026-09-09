; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-array-element-interface-skipped.cblog %s 2>&1 | FileCheck %s

; The element klass of the array is an unverified interface: no metadata may be
; attached (same rule as the frontend and the field-load path).

define void @test(ptr addrspace(1) "java-klass"="20" %arr, i64 %idx) #0 gc "hotspotgc" {
entry:
  %base = getelementptr i8, ptr addrspace(1) %arr, i64 16
  %elem_addr = getelementptr ptr addrspace(1), ptr addrspace(1) %base, i64 %idx
  %elem = load ptr addrspace(1), ptr addrspace(1) %elem_addr
  ret void
}

; CHECK: entry:
; No !java-klass must be attached to the load (scoped CHECK-NOT avoids the
; java-klass attribute on the parameter in the function signature).
; CHECK-NOT: java-klass
; CHECK: ret void

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
