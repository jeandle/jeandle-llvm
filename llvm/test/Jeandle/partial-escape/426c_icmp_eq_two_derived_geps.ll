; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Variant: two derived GEPs of the same virtual at DIFFERENT offsets
; (%g1 at 8, %g2 at 16). Both resolve to %o's ObjectID, but the addresses
; differ, so `icmp eq %g1, %g2` must fold to false, not true.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i1)
declare i32 @__gxx_personality_v0(...)

define void @test_icmp_eq_two_derived_geps() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
         to label %n unwind label %u
n:
  %g1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %g2 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %c = icmp eq ptr addrspace(1) %g1, %g2
  call void @use(i1 %c)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_icmp_eq_two_derived_geps
; CHECK: call{{.*}}@use(i1 false)
; CHECK-NOT: call{{.*}}@use(i1 true)

!java-method-compilation = !{}
