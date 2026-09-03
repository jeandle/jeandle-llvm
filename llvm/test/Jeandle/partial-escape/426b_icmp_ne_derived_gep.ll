; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Variant: `icmp ne ptr %o, ptr %g` with %g = gep %o, 8. Distinct
; addresses -> ne is TRUE. Folding the equal ObjectID to eq=true and then
; negating (ne) would wrongly give false.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i1)
declare i32 @__gxx_personality_v0(...)

define void @test_icmp_ne_derived_gep() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
         to label %n unwind label %u
n:
  %g = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %c = icmp ne ptr addrspace(1) %o, %g
  call void @use(i1 %c)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_icmp_ne_derived_gep
; Distinct addresses -> ne yields true.
; CHECK: call{{.*}}@use(i1 true)
; CHECK-NOT: call{{.*}}@use(i1 false)

!java-method-compilation = !{}
