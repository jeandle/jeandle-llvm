; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-instance-field.cblog %s 2>&1 | FileCheck %s

; Base oop comes in with a java-klass attribute (klass 5), which survives load
; CSE. The field load at offset 16 lost its !java-klass metadata; RecoverTypeInfo
; recomputes it via GetFieldType(5, 16) = klass 7.

define void @test(ptr addrspace(1) "java-klass"="5" %obj) #0 gc "hotspotgc" {
entry:
  %addr = getelementptr i8, ptr addrspace(1) %obj, i64 16
  %field = load ptr addrspace(1), ptr addrspace(1) %addr
  ret void
}

; CHECK: %field = load ptr addrspace(1), ptr addrspace(1) %addr{{.*}}, !java-klass ![[K:[0-9]+]]
; CHECK: ![[K]] = !{i64 7}
; CHECK-NOT: java-klass-exact

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
