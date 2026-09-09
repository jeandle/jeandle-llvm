; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; REQUIRES: asserts

; Lock-stack depth monotonicity asserts mirror ObjectState::addLock.
; Re-entrant locks on the SAME object acquire strictly
; increasing bytecode depth (0 then 1); the debug asserts in ObjectState::addLock
; and the LiveLockEnters push must accept this and not false-fire. (Two DISTINCT
; virtual objects would instead trigger the elide-path cascade, so a single
; re-entrant object isolates the monotonicity check.) The object never escapes,
; so the alloc, both enters and both exits all eliminate.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare i32 @__gxx_personality_v0(...)

define void @test_reentrant_lock_depth_monotonic() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %l0 = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %a, ptr %l0)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %a, ptr %l0)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %a, ptr %l0)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %a, ptr %l0)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_reentrant_lock_depth_monotonic
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.monitorenter_with_lightweight_lock
; CHECK-NOT: jeandle.monitorexit_with_lightweight_lock

!java-method-compilation = !{}
