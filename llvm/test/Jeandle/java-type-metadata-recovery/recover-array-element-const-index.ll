; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-array-element-const-index.cblog %s 2>&1 | FileCheck %s

; Array element load with a constant index: the address strips to (array oop,
; constant offset), which is structurally indistinguishable from a field load.
; RecoverTypeInfo must resolve array-ness from the base klass first
; (ArrayElementKlass(20) = 21) instead of consulting GetFieldType, which
; returns 0 for array klasses.

define void @test(ptr addrspace(1) "java-klass"="20" %arr) #0 gc "hotspotgc" {
entry:
  %elem_addr = getelementptr i8, ptr addrspace(1) %arr, i64 24
  %elem = load ptr addrspace(1), ptr addrspace(1) %elem_addr
  ret void
}

; CHECK: %elem = load ptr addrspace(1), ptr addrspace(1) %elem_addr{{.*}}, !java-klass ![[K:[0-9]+]]
; CHECK: ![[K]] = !{i64 21}

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
