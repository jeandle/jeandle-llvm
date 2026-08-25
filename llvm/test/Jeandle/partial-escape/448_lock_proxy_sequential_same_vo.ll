; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; CFG-depth guard: SEQUENTIAL (non-nested) locks on the SAME virtual object,
; with no `!jeandle.lock_depth` metadata. The object is locked, released, then
; locked again as two independent synchronized regions:
;   synchronized(o) { }   // balanced, never escapes -> fully elided
;   synchronized(o) { escape(o); }   // unbalanced enter survives, o materialises
;
; CFG dataflow assigns depth 0 to both enter sites because the first lock is
; released before the second is acquired. foldMonitorExit pops the first enter
; off the per-VO lock stack before the second is pushed. Only the second enter,
; which is live when the object escapes, is re-emitted at the materialise point;
; the first balanced enter/exit pair is fully elided and never re-emitted.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_proxy_sequential_same_vo() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %l1 = alloca i64, align 8
  %l2 = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 24680 to ptr), i32 16, i1 false)
         to label %n unwind label %u
n:
  ; First synchronized(o) region — balanced, never escapes.
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %o, ptr %l1)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %o, ptr %l1)
  ; Second synchronized(o) region — independent; o escapes while locked.
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
                  ptr addrspace(1) %o, ptr %l2)
  call void @sink(ptr addrspace(1) %o)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
                  ptr addrspace(1) %o, ptr %l2)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_proxy_sequential_same_vo
; o materialises at the sink; the second live enter is re-emitted there.
; CHECK: invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 24680 to ptr), i32 16, i1 false)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %[[MAT:[A-Za-z0-9._]+]], ptr %l2)
; The matching monitorexit for the second region survives, RAUW'd to %[[MAT]].
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %[[MAT]], ptr %l2)
; The first balanced region is fully elided: its enter and exit must NOT appear.
; CHECK-NOT: monitorenter_with_lightweight_lock(ptr addrspace(1) %{{[^,]+}}, ptr %l1)
; CHECK-NOT: monitorexit_with_lightweight_lock(ptr addrspace(1) %{{[^,]+}}, ptr %l1)
; Only ONE re-emitted monitorenter total (the second region's).
; CHECK: ret void

!java-method-compilation = !{}
