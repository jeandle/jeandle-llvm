; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-stale-exact-flag.cblog %s 2>&1 | FileCheck %s

; A load that carries a lone !java-klass-exact flag without !java-klass (a
; shape upstream passes can leave behind when the two are not stripped
; together) must not keep that flag when RecoverTypeInfo attaches a fresh,
; non-exact klass: the combination would be read as an unproven exact type by
; every consumer. The stale flag is dropped along with the recovery.

define void @test(ptr addrspace(1) "java-klass"="5" %obj) #0 gc "hotspotgc" {
entry:
  %addr = getelementptr i8, ptr addrspace(1) %obj, i64 16
  %field = load ptr addrspace(1), ptr addrspace(1) %addr, !java-klass-exact !0
  ret void
}

; CHECK: %field = load ptr addrspace(1), ptr addrspace(1) %addr
; The stale exact flag must be gone by the time the klass is attached.
; CHECK-NOT: java-klass-exact
; CHECK: , !java-klass ![[K:[0-9]+]]
; CHECK: ![[K]] = !{i64 7}

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
!0 = !{}
