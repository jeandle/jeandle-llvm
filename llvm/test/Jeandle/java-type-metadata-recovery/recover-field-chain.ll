; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-field-chain.cblog %s 2>&1 | FileCheck %s

; Multi-level field chain off a constant oop. The base load comes from an
; oop_handle global (GetOopKlass seed), and each successive field load's base is
; the previously recovered field load. Exercises the worklist propagating
; recovered klass info down a def-use chain.

@oop_handle_Root_0 = external global ptr addrspace(1)

define void @test() #0 gc "hotspotgc" {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Root_0
  %child.addr = getelementptr i8, ptr addrspace(1) %base, i64 16
  %child = load ptr addrspace(1), ptr addrspace(1) %child.addr
  %grand.addr = getelementptr i8, ptr addrspace(1) %child, i64 20
  %grand = load ptr addrspace(1), ptr addrspace(1) %grand.addr
  ret void
}

; CHECK: %child = load ptr addrspace(1), ptr addrspace(1) %child.addr{{.*}}, !java-klass ![[C:[0-9]+]]
; CHECK: %grand = load ptr addrspace(1), ptr addrspace(1) %grand.addr{{.*}}, !java-klass ![[G:[0-9]+]], !java-klass-exact
; CHECK: ![[C]] = !{i64 7}
; CHECK: ![[G]] = !{i64 9}
; base is an oop_handle load: RecoverTypeInfo must NOT attach metadata to it
; (getBaseJavaType resolves it via getOopHandleId at query time).
; CHECK-NOT: %base = load ptr addrspace(1), ptr @oop_handle_Root_0{{.*}}!java-klass

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
