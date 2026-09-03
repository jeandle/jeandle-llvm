; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/390_register_finalizer_if_needed_bails.cblog %s | FileCheck %s

; If the exact klass has a finalizer, tier1 refuses virtualization. PEA must
; keep the original allocation and register_finalizer_if_needed JavaOp so
; HotSpot can register the finalizer.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.register_finalizer_if_needed(ptr addrspace(1))

declare i32 @__gxx_personality_v0(...)

define void @test_register_finalizer_if_needed_bails() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 9998 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  call hotspotcc void @jeandle.register_finalizer_if_needed(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_register_finalizer_if_needed_bails
; CHECK: invoke{{.*}}@jeandle.new_instance{{.*}}i64 9998
; CHECK: call{{.*}}@jeandle.register_finalizer_if_needed

!java-method-compilation = !{}
