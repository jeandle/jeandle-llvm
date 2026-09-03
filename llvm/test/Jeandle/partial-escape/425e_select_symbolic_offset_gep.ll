; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Select of symbolic-offset derived GEPs into a virtual object. %g1 and %g2 are
; gep %o, %idx where %idx is a non-constant SSA value, so resolveFieldOffset
; returns nullopt and the select is NOT alias-forwarded. The generic escape
; path materializes %o at the select: under
; reuse-OrigAlloc OrigAlloc dominates the pre-computed arms, so they stay
; valid. The object survives (PartiallyEscapes) with its tracked store (7 at
; offset 0) replayed via pea.matslot before the select, the select/load
; survive reading the real address, and the load is NOT folded to the
; field@0 value 7 (a symbolic-offset access is untrackable).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_select_symbolic_offset_gep(i1 %c, i64 %idx) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
         to label %n unwind label %u
n:
  %f0 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 0
  %g1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 %idx
  %g2 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 %idx
  store atomic i32 7, ptr addrspace(1) %f0 unordered, align 4
  %sel = select i1 %c, ptr addrspace(1) %g1, ptr addrspace(1) %g2
  %r = load atomic i32, ptr addrspace(1) %sel unordered, align 4
  call void @use(i32 %r)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_select_symbolic_offset_gep
; CHECK-NOT: getelementptr{{.*}}poison
; CHECK: invoke{{.*}}@jeandle.new_instance
; CHECK: select i1 %c
; CHECK: load atomic i32, ptr addrspace(1) %sel
; CHECK-NOT: call{{.*}}@use(i32 7)

!java-method-compilation = !{}
