; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Select of equal-offset derived GEPs into a virtual object. %g1 and %g2 both
; offset %o by 16; %sel = select %c, %g1, %g2; the load is through %sel, whose
; runtime address is %o+16 (field @16 = 42). A select does not preserve the
; byte offset in the alias map, so PEA replays tracked state onto OrigAlloc at
; the select and leaves the select/load real instead of mis-modelling it as
; offset 0. OrigAlloc dominates both precomputed GEP arms, so they remain
; valid; the load is not folded to the field@0 value 7.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_select_equal_offset_gep(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
  ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
  to label %n unwind label %u
n:
  %f0 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 0
  %g1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %g2 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 7, ptr addrspace(1) %f0 unordered, align 4
  store atomic i32 42, ptr addrspace(1) %g1 unordered, align 4
  %sel = select i1 %c, ptr addrspace(1) %g1, ptr addrspace(1) %g2
  %r = load atomic i32, ptr addrspace(1) %sel unordered, align 4
  call void @use(i32 %r)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_select_equal_offset_gep
; The GEP arms must keep a real base (never poison) — checked first so the
; CHECK-NOT scope spans the function body where the (pre-fix) poison GEPs sit.
; CHECK-NOT: getelementptr{{.*}}poison
; The object stays real and the load survives through %sel reading %o+16.
; CHECK: invoke{{.*}}@jeandle.new_instance
; CHECK: load atomic i32, ptr addrspace(1) %sel
; The load must NOT fold to the field@0 value 7.
; CHECK-NOT: call{{.*}}@use(i32 7)

!java-method-compilation = !{}
