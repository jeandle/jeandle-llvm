; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Narrow cascade driven by CFG-derived lock depth. Mirrors
; partial-escape/190_narrow_lock_cascade_nested.ll with the depth sourced from
; the analyzer's control-flow dataflow (no `!jeandle.lock_depth` metadata).
; Outer A (depth=0), inner B (depth=1). Inner B escapes; the cascade rule
;   other.front().BytecodeDepth < this.back().BytecodeDepth
; selects A (A.minDepth=0 < B.maxDepth=1), so A also materialises.
;
; The behaviour is identical to test 190 — the point here is to drive the
; depth-aware rule end-to-end from depths reconstructed from the CFG.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_lockdepth_cascade_metadata() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock_a = alloca i64, align 8
  %lock_b = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
       to label %na unwind label %u
na:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
       to label %nb unwind label %u
nb:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %a, ptr %lock_a)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %b, ptr %lock_b)
  call void @sink(ptr addrspace(1) %b)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %b, ptr %lock_b)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %a, ptr %lock_a)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Cascade fires: both A and B materialize. Each materialize re-emits its
; monitorenter (outer A before inner B); the exits survive at source.
; CHECK-LABEL: define void @test_lockdepth_cascade_metadata
; CHECK: %[[MATA:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
; CHECK: %[[MATB:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %[[MATA]],
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %[[MATB]],
; CHECK: call void @sink(ptr addrspace(1) %[[MATB]])
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %[[MATB]],
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %[[MATA]],

!java-method-compilation = !{}
