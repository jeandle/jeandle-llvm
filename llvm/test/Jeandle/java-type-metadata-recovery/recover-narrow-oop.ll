; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-narrow-oop.cblog %s 2>&1 | FileCheck %s

; Compressed (narrow, AS3) field load. The base is a narrow oop with a java-klass
; attribute; RecoverTypeInfo must recover the field type and attach !java-klass
; to the narrow load exactly as the frontend would before the addrspacecast
; decode.

define void @test(ptr addrspace(3) "java-klass"="5" %obj) #0 gc "hotspotgc" {
entry:
  %addr = getelementptr i8, ptr addrspace(3) %obj, i64 16
  %field = load ptr addrspace(3), ptr addrspace(3) %addr
  %decoded = addrspacecast ptr addrspace(3) %field to ptr addrspace(1)
  ret void
}

; CHECK: %field = load ptr addrspace(3), ptr addrspace(3) %addr{{.*}}, !java-klass ![[K:[0-9]+]]
; CHECK: ![[K]] = !{i64 7}

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
