; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-assume-strict-lock-order=false %s | FileCheck %s

; PEA: -jeandle-assume-strict-lock-order=false overrides the
; RequiresStrictLockOrder VMCallback (testing path,
; getNumOccurrences() > 0 wins). The CFG mirrors 43_strict_lock_order_cascade.ll
; (two virtuals A and B, nested enter A then enter B, escape of A while
; both locked) so the contrast is direct: with strict-order, the cascade
; forces B to materialize at A's escape; with strict-order=false, B has
; no escape of its own and stays virtual — its monitorenter / monitorexit
; calls fold away.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_no_strict_lock_cascade() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock_a = alloca i64, align 8
  %lock_b = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %na unwind label %u
na:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
       to label %nb unwind label %u
nb:
  ; Acquire outer A.
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %a, ptr %lock_a)
  ; Acquire inner B.
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %b, ptr %lock_b)
  ; Escape: A leaks through a sink while both locks held.
  call void @sink(ptr addrspace(1) %a)
  ; Release inner B.
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %b, ptr %lock_b)
  ; Release outer A.
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %a, ptr %lock_a)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A must still materialize (sink escapes it).
; CHECK-LABEL: define void @test_no_strict_lock_cascade
; CHECK: %[[MATA:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
; A's enter on materialized A, sink on materialized A, A's exit on materialized A.
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %[[MATA]],
; CHECK: call void @sink(ptr addrspace(1) %[[MATA]])
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %[[MATA]],
; B must NOT be materialized and its monitor calls must NOT survive: the
; strict-lock cascade is the only thing that would materialize B here, and
; we've explicitly disabled it.
; CHECK-NOT: jeandle.new_instance(ptr inttoptr (i64 67890 to ptr)
; CHECK-NOT: ptr %lock_b

!java-method-compilation = !{}
