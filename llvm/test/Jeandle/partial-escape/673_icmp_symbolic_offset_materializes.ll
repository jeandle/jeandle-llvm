; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; foldICmpEquality: same virtual object on both sides, one via a
; symbolic-offset GEP — the offsets can be proven neither equal nor
; distinct, so the icmp cannot fold. The object materializes AT the icmp
; reuse-OrigAlloc keeps both derived operands
; valid, the tracked store is replayed before the icmp, the earlier folded
; load stays folded, and the icmp survives as a real compare. Regression
; guard: marking the object ineligible instead would drop the fold
; function-wide.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i1)
declare void @use_int(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_icmp_symbolic(i64 %sym) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
       to label %n unwind label %u
n:
  %f = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 33, ptr addrspace(1) %f unordered, align 4
  %r = load atomic i32, ptr addrspace(1) %f unordered, align 4
  call void @use_int(i32 %r)
  %g = getelementptr inbounds i8, ptr addrspace(1) %o, i64 %sym
  %c = icmp eq ptr addrspace(1) %o, %g
  call void @use(i1 %c)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_icmp_symbolic
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; The folded load STAYS folded (a bail would drop it function-wide).
; CHECK: call void @use_int(i32 33)
; The tracked store is replayed immediately before the icmp.
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
; CHECK: store atomic i32 33, ptr addrspace(1) %pea.matslot unordered, align 4
; The icmp survives as a real compare (not folded either way).
; CHECK: %c = icmp eq ptr addrspace(1) %o, %g
; CHECK: call void @use(i1 %c)
; CHECK-NOT: poison

!java-method-compilation = !{}
