; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; ptrtoint on a virtual is a Java-identity surrogate (it observes the
; pointer value, e.g. for identity hash) and must force materialization.
; PtrToIntInst is not in the propagatePointerAlias passthrough set, so
; tier-2 falls through to materializeAllVirtualOperands.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use_int(i64)
declare i32 @__gxx_personality_v0(...)

define void @test_ptrtoint() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %as_int = ptrtoint ptr addrspace(1) %o to i64
  call void @use_int(i64 %as_int)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_ptrtoint
; CHECK: jeandle.new_instance
; CHECK: ptrtoint ptr addrspace(1)
; CHECK: call void @use_int

!java-method-compilation = !{}
