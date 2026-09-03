; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; materializeVirtualCallArgs: a call whose arguments mix a DERIVED pointer of
; one virtual object (gep(%a, 8)) and a DIRECT OrigAlloc of another (%b).
; The generic escape path materializes each virtual input independently at
; the call; reuse-OrigAlloc keeps both allocations alive and replays %b's
; tracked field store immediately before the call. Regression guard: the
; derived argument must not trigger a bail-all that marks BOTH objects
; ineligible (which would leave %b's tracked store at its original site).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink2(ptr addrspace(1), ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_mixed_args() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
       to label %n1 unwind label %u
n1:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 22222 to ptr), i32 32, i1 false)
       to label %n2 unwind label %u
n2:
  %f = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 77, ptr addrspace(1) %f unordered, align 4
  %g = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  call void @sink2(ptr addrspace(1) %g, ptr addrspace(1) %b)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_mixed_args
; Both allocations survive (both materialize at the call => PartiallyEscapes).
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; %b's tracked store is replayed onto OrigAlloc immediately before the call
; (the replay slot is named pea.matslot).
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
; CHECK: store atomic i32 77, ptr addrspace(1) %pea.matslot unordered, align 4
; The call keeps the live derived pointer and OrigAlloc.
; CHECK: call void @sink2(ptr addrspace(1) %g, ptr addrspace(1) %b)
; CHECK-NOT: poison

!java-method-compilation = !{}
