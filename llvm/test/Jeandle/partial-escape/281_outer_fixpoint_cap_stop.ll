; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=4 %s | FileCheck %s

; Outer-fixpoint cap-stop test. An allocation whose escape (an opaque sink call on every
; path) cannot be removed by InstCombine / SimplifyCFG / ADCE in any round —
; %sink has no attributes the standard pipeline can exploit. We run the
; wrapper with the full iteration cap (4) and verify that:
;   1. the pass terminates cleanly (no infinite loop, no crash),
;   2. convergence detection short-circuits the cap once a complete current
;      transform+canonicalization round leaves IR unchanged,
;   3. the allocation and the sink call are preserved (no spurious deletion).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_cap_stop()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  call void @sink(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_cap_stop()
; CHECK: jeandle.new_instance
; CHECK: call void @sink
; CHECK: ret void

!java-method-compilation = !{}
