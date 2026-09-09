; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Exception edge state splitting — regression test for a handler
; whose only purpose is to re-throw via `resume`. Such handlers have no
; per-object state of their own; the state-split must not leave the
; analyzer in a confused state (e.g. by treating the pre-invoke snapshot
; as authoritative for a sink-only handler).
;
; The escape retains OrigAlloc; replay effects, if any, are inserted before
; the consumer invoke. The handler block must remain well-formed (landingpad +
; resume present, no dangling SSA references).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_292() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
       to label %n unwind label %u_a
n:
  ; This invoke materializes VO_A. The unwind successor is a
  ; re-throwing handler that ignores VO_A entirely.
  invoke void @sink(ptr addrspace(1) %a)
       to label %nfinal unwind label %handler
nfinal:
  ret void
handler:
  %lp = landingpad i64 cleanup
  resume i64 %lp
u_a:
  %lpa = landingpad i64 cleanup
  resume i64 %lpa
}

; VO_A's source allocation is retained as the only allocation and the handler
; still terminates with `resume`.
; CHECK-LABEL: define void @test_292
; CHECK: %a = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
; CHECK-NOT: @jeandle.new_instance
; CHECK: invoke void @sink(ptr addrspace(1) %a)
; CHECK: resume i64

!java-method-compilation = !{}
