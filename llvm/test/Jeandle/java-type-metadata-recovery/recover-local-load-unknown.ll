; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-local-load-unknown.cblog %s 2>&1 | FileCheck %s

; Base of the field load is itself a load from a stack slot (an interpreter
; local). The stack slot is not a Java object, so the local's klass is
; unknowable (Bottom); the downstream field load must therefore NOT be recovered.
; Soundness check.

define void @test() #0 gc "hotspotgc" {
entry:
  %slot = alloca ptr addrspace(1)
  %local = load ptr addrspace(1), ptr %slot
  %addr = getelementptr i8, ptr addrspace(1) %local, i64 16
  %field = load ptr addrspace(1), ptr addrspace(1) %addr
  ret void
}

; CHECK-NOT: java-klass

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
