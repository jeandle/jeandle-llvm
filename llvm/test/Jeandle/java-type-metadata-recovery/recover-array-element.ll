; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-array-element.cblog %s 2>&1 | FileCheck %s

; Array element load with a variable index: the address is an interior pointer
; produced by a variable-index GEP, so the load cannot be typed from a field
; offset. RecoverTypeInfo must peel the addressing to the array oop (an
; argument with java-klass attribute 20, an object-array klass), query the
; element klass via ArrayElementKlass and attach it as !java-klass.

define void @test(ptr addrspace(1) "java-klass"="20" %arr, i64 %idx) #0 gc "hotspotgc" {
entry:
  %base = getelementptr i8, ptr addrspace(1) %arr, i64 16
  %elem_addr = getelementptr ptr addrspace(1), ptr addrspace(1) %base, i64 %idx
  %elem = load ptr addrspace(1), ptr addrspace(1) %elem_addr
  ret void
}

; CHECK: %elem = load ptr addrspace(1), ptr addrspace(1) %elem_addr{{.*}}, !java-klass ![[K:[0-9]+]]
; CHECK: ![[K]] = !{i64 21}
; CHECK-NOT: java-klass-exact

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
