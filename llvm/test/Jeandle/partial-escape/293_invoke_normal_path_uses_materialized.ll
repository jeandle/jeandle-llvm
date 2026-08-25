; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Exception edge state splitting — regression test for the NORMAL
; successor of an invoke that materialized one of its operands. A
; separate pre-invoke snapshot is used for the unwind successor, but
; the normal successor must continue to inherit the post-invoke state
; (i.e. it sees VO_A as Materialized, backed by OrigAlloc).
;
; A subsequent use of VO_A on the normal path must thread through the
; retained allocation. The test below uses @sink2 (a second opaque
; consumer on the normal path) to anchor that pointer.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare void @sink2(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_293() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
       to label %n unwind label %u_a
n:
  ; First @sink escapes VO_A, materializing it before the invoke.
  invoke void @sink(ptr addrspace(1) %a)
       to label %nfinal unwind label %handler
nfinal:
  ; Normal successor: another consumer of VO_A. Must see the materialized
  ; pointer, which is the retained OrigAlloc.
  call void @sink2(ptr addrspace(1) %a)
  ret void
handler:
  %lp = landingpad i64 cleanup
  resume i64 %lp
u_a:
  %lpa = landingpad i64 cleanup
  resume i64 %lpa
}

; The original allocation is the sole new_instance. Both consumers use it.
; CHECK-LABEL: define void @test_293
; CHECK: %[[ORIG:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
; CHECK-NOT: @jeandle.new_instance
; CHECK: invoke void @sink(ptr addrspace(1) %[[ORIG]])
; CHECK: call void @sink2(ptr addrspace(1) %[[ORIG]])

!java-method-compilation = !{}
