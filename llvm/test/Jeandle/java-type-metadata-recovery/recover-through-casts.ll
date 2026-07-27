; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-through-casts.cblog %s 2>&1 | FileCheck %s

; The base oop flows through a chain of pointer-preserving casts (addrspacecast,
; bitcast, freeze) before the field load. These are all forwarders, so the klass
; propagates through and the field load recovers. Exercises pass-through
; transfer across multiple cast kinds that earlier passes may introduce.

define void @test(ptr addrspace(1) "java-klass"="5" %obj) #0 gc "hotspotgc" {
entry:
  %c1 = freeze ptr addrspace(1) %obj
  %c2 = addrspacecast ptr addrspace(1) %c1 to ptr addrspace(3)
  %c3 = addrspacecast ptr addrspace(3) %c2 to ptr addrspace(1)
  %z = getelementptr ptr addrspace(1), ptr addrspace(1) %c3, i64 0
  %addr = getelementptr i8, ptr addrspace(1) %z, i64 16
  %field = load ptr addrspace(1), ptr addrspace(1) %addr
  ret void
}

; CHECK: %field = load ptr addrspace(1), ptr addrspace(1) %addr{{.*}}, !java-klass ![[K:[0-9]+]]
; CHECK: ![[K]] = !{i64 7}

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
