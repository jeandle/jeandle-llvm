; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Select of DIVERGENT-offset derived GEPs into a virtual object. %g1 at offset
; 16, %g2 at offset 24. As the equal-offset case, the GEP arms are computed
; before any materialize point, so PEA keeps %o real (markIneligible) instead
; of materializing at the select (which would poison the arms). The load
; survives reading the real address and is NOT folded to the field@0 value 7.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_select_divergent_offset_gep(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
         to label %n unwind label %u
n:
  %f0 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 0
  %g1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %g2 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 24
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

; CHECK-LABEL: define void @test_select_divergent_offset_gep
; CHECK-NOT: getelementptr{{.*}}poison
; CHECK: invoke{{.*}}@jeandle.new_instance
; CHECK: load atomic i32, ptr addrspace(1) %sel
; CHECK-NOT: call{{.*}}@use(i32 7)

!java-method-compilation = !{}
