; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/preserve-existing-metadata.cblog %s 2>&1 | FileCheck %s

; A field load that still carries !java-klass (was not CSE'd away) must be left
; untouched (idempotent), while a second field load off the same base that lost
; its metadata gets recovered.

define void @test(ptr addrspace(1) "java-klass"="5" %obj) #0 gc "hotspotgc" {
entry:
  %addr = getelementptr i8, ptr addrspace(1) %obj, i64 16
  %kept = load ptr addrspace(1), ptr addrspace(1) %addr, !java-klass !0
  %addr2 = getelementptr i8, ptr addrspace(1) %obj, i64 24
  %recovered = load ptr addrspace(1), ptr addrspace(1) %addr2
  ret void
}

; CHECK: %kept = load ptr addrspace(1), ptr addrspace(1) %addr{{.*}}, !java-klass !0
; CHECK: %recovered = load ptr addrspace(1), ptr addrspace(1) %addr2{{.*}}, !java-klass ![[K:[0-9]+]]
; CHECK: !0 = !{i64 42}
; CHECK: ![[K]] = !{i64 7}

attributes #0 = { "java-method"="0" }

!0 = !{i64 42}
!java-method-compilation = !{}
