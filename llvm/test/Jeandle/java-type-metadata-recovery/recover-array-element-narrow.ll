; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-array-element-narrow.cblog %s 2>&1 | FileCheck %s

; Compressed-oops aaload: the array oop is wide (AS1) but the element load is
; narrow (AS3). RecoverTypeInfo must attach !java-klass to the narrow load.

define void @test(ptr addrspace(1) "java-klass"="20" %arr, i64 %idx) #0 gc "hotspotgc" {
entry:
  %base = getelementptr i8, ptr addrspace(1) %arr, i64 16
  %elem_addr = getelementptr ptr addrspace(3), ptr addrspace(1) %base, i64 %idx
  %elem = load ptr addrspace(3), ptr addrspace(1) %elem_addr
  %decoded = addrspacecast ptr addrspace(3) %elem to ptr addrspace(1)
  ret void
}

; CHECK: %elem = load ptr addrspace(3), ptr addrspace(1) %elem_addr{{.*}}, !java-klass ![[K:[0-9]+]]
; CHECK: ![[K]] = !{i64 21}

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
