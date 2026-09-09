; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/389_register_finalizer_if_needed_elided.cblog %s | FileCheck %s

; A virtual receiver whose exact klass has no finalizer does not need the
; register_finalizer_if_needed JavaOp. Folding the void JavaOp leaves the
; allocation unused, so the allocation is eliminated too.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.register_finalizer_if_needed(ptr addrspace(1))

declare i32 @__gxx_personality_v0(...)

define void @test_register_finalizer_if_needed_elided() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 8888 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  call hotspotcc void @jeandle.register_finalizer_if_needed(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_register_finalizer_if_needed_elided
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.register_finalizer_if_needed
; CHECK: ret void

!java-method-compilation = !{}
