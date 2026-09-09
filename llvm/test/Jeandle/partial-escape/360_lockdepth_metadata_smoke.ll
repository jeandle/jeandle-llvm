; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; CFG lock-depth smoke test: a single virtual whose monitorenter carries NO
; `!jeandle.lock_depth` metadata (the frontend does not attach it). The
; fold-elide path must still fire (the alloc, enter, exit and field stores all
; eliminate). This exercises the ordinary-entry CFG depth path on a positive
; case and confirms the derived depth flows through ObjectState::Locks and the
; analyzer-side LiveLockEnters without disturbing the unlocked / no-escape
; behaviour exercised by
; partial-escape/12_monitorenter_exit_elided.ll.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare i32 @__gxx_personality_v0(...)

define void @test_lockdepth_metadata_smoke() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 4242 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %o, ptr %lock)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %o, ptr %lock)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The allocation and both monitor calls are fully elided because the VO
; never escapes.
; CHECK-LABEL: define void @test_lockdepth_metadata_smoke
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.monitorenter_with_lightweight_lock
; CHECK-NOT: jeandle.monitorexit_with_lightweight_lock

!java-method-compilation = !{}
