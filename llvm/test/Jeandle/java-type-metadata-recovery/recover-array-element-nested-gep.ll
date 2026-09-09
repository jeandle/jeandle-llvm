; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-array-element-nested-gep.cblog %s 2>&1 | FileCheck %s

; Nested variable-index addressing: the address is
; gep (gep arr, %i), %j — two variable-index GEP layers. RecoverTypeInfo must
; peel every layer (not just the outermost) to reach the array oop and type
; the load from the array's element klass.

define void @test(ptr addrspace(1) "java-klass"="20" %arr, i64 %i, i64 %j) #0 gc "hotspotgc" {
entry:
  %l1 = getelementptr ptr addrspace(1), ptr addrspace(1) %arr, i64 %i
  %l2 = getelementptr ptr addrspace(1), ptr addrspace(1) %l1, i64 %j
  %elem = load ptr addrspace(1), ptr addrspace(1) %l2
  ret void
}

; CHECK: %elem = load ptr addrspace(1), ptr addrspace(1) %l2{{.*}}, !java-klass ![[K:[0-9]+]]
; CHECK: ![[K]] = !{i64 21}

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
