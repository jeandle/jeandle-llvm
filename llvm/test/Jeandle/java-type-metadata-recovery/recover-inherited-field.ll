; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-inherited-field.cblog %s 2>&1 | FileCheck %s

; The base oop's declared klass is a SUBclass (7) that does not itself declare
; the field; the field is declared in superclass (5). GetFieldType must walk the
; superclass chain (GetFieldType(7,16) finds the inherited field of type 9).
; Validates the hierarchical GetFieldType semantics.

define void @test(ptr addrspace(1) "java-klass"="7" %obj) #0 gc "hotspotgc" {
entry:
  %addr = getelementptr i8, ptr addrspace(1) %obj, i64 16
  %field = load ptr addrspace(1), ptr addrspace(1) %addr
  ret void
}

; CHECK: %field = load ptr addrspace(1), ptr addrspace(1) %addr{{.*}}, !java-klass ![[K:[0-9]+]]
; CHECK: ![[K]] = !{i64 9}

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
