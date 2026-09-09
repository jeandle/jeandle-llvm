; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A PartiallyEscapes object materializes by replaying its field stores onto
; its ORIGINAL allocation (OrigAlloc), which is kept alive, so the original
; allocation's own deopt operand bundle is preserved verbatim. Here the
; allocation carries a "deopt" bundle and the sink does not; after PEA the
; original invoke (with its bundle) is retained and the sink receives
; OrigAlloc directly.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_mat_deopt() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       [ "deopt"(i32 42) ]
       to label %n unwind label %u
n:
  call void @sink(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_mat_deopt
; The original allocation invoke is RETAINED with its deopt bundle intact.
; CHECK: = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr {{.*}}, i32 16, i1 false) [ "deopt"(i32 42) ]
; CHECK: to label %{{.*}} unwind label %{{.*}}
; The sink receives the original allocation directly.
; CHECK: call void @sink(ptr addrspace(1) %o)

!java-method-compilation = !{}
