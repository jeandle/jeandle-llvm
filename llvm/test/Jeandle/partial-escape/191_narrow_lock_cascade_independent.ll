; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Two virtuals whose lock scopes are DISJOINT (sequential, not
; nested). When B escapes, A is no longer live-locked, so there's no
; cascade to perform — A's monitorenter/exit pair fold away cleanly.
; Both the broad and narrow rules agree here; this test is a regression
; guard that ensures the narrow rule's "iterate LiveLockEnters and check
; min < this.max" doesn't accidentally pick up VOs with zero live locks.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_narrow_cascade_independent() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock_a = alloca i64, align 8
  %lock_b = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 33333 to ptr), i32 16, i1 false)
       to label %na unwind label %u
na:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 44444 to ptr), i32 16, i1 false)
       to label %nb unwind label %u
nb:
  ; First sync region: A, fully balanced.
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %a, ptr %lock_a)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %a, ptr %lock_a)
  ; Second sync region: B, escapes inside.
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %b, ptr %lock_b)
  call void @sink(ptr addrspace(1) %b)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %b, ptr %lock_b)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; B materializes (escapes); A stays virtual and folds away entirely.
; CHECK-LABEL: define void @test_narrow_cascade_independent
; CHECK: %[[MATB:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 44444 to ptr), i32 16, i1 false)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %[[MATB]],
; CHECK: call void @sink(ptr addrspace(1) %[[MATB]])
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %[[MATB]],
; A must NOT materialize, and none of its monitor calls or lock_a alloca
; uses should survive (lock_a may stay as a dead alloca, but no monitor
; call should reference it).
; CHECK-NOT: jeandle.new_instance(ptr inttoptr (i64 33333 to ptr)
; CHECK-NOT: jeandle.monitorenter_with_lightweight_lock{{.*}}%lock_a
; CHECK-NOT: jeandle.monitorexit_with_lightweight_lock{{.*}}%lock_a

!java-method-compilation = !{}
