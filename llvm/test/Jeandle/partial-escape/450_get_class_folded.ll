; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/450_get_class_folded.cblog %s | FileCheck %s

; PEA: jeandle.get_class on a virtual receiver (whose exact klass is known)
; folds to a GC-safe load of the java.lang.Class mirror oop-handle, and the
; non-escaping allocation is eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1))

declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @test_get_class() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 7 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %c = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %o)
  ret ptr addrspace(1) %c
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @test_get_class
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.get_class
; CHECK: load ptr addrspace(1), ptr @oop_handle_
; CHECK: ret ptr addrspace(1)

!java-method-compilation = !{}
