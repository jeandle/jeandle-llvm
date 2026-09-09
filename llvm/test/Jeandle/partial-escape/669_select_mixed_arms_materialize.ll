; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; propagatePointerAlias select case: both arms resolve to the SAME virtual
; object but one arm is a derived GEP — not whole-object, so no
; alias-forward. The select is handed to the generic escape path, which
; materializes the object AT the select:
; reuse-OrigAlloc keeps the allocation and replays the tracked store before
; the select; the select's operands stay valid real pointers. Regression
; guard: the derived arm must not force a bail of the object
; (markIneligible), which would leave the tracked store in place.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_select_mixed_arms(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
       to label %n unwind label %u
n:
  %f = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 55, ptr addrspace(1) %f unordered, align 4
  %g = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %s = select i1 %c, ptr addrspace(1) %o, ptr addrspace(1) %g
  call void @sink(ptr addrspace(1) %s)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_select_mixed_arms
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; The tracked store is replayed before the select.
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
; CHECK: store atomic i32 55, ptr addrspace(1) %pea.matslot unordered, align 4
; The select survives as a real select over real pointers.
; CHECK: %s = select i1 %c, ptr addrspace(1) %o, ptr addrspace(1) %g
; CHECK: call void @sink(ptr addrspace(1) %s)
; CHECK-NOT: poison

!java-method-compilation = !{}
