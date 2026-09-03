; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Cross-VO lock re-emit ordering with a RE-ENTRANT interleaved lock stack
; The lexical nest is:
; synchronized(a){ synchronized(b){ synchronized(a){ synchronized(c){
; escape(c);
; so at the escape point the live lock stack is [a@0, b@1, a@2, c@3]. Escaping
; c (depth 3) cascades a (front 0 < 3) and b (front 1 < 3); all three VO
; materialize at the same escape point.
;
; a's effect carries Locks=[a@0, a@2], b's=[b@1], c's=[c@3]. Re-emitting per
; effect (a's two enters, then b's, then c's) yields depth order 0,2,1,3 -- NOT
; strictly increasing, which violates the lightweight-lock thread-stack
; contract. All locks materialized at one escape point are merged and
; re-emitted globally sorted by depth (0,1,2,3), matching the single
; materialize-commit + depth-sorted lowering.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_reentrant_interleaved_cascade() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %la = alloca i64, align 8
  %lb = alloca i64, align 8
  %la2 = alloca i64, align 8
  %lc = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
  ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
  to label %na unwind label %u
na:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
  ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
  to label %nb unwind label %u
nb:
  %c = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
  ptr inttoptr (i64 33333 to ptr), i32 16, i1 false)
  to label %nc unwind label %u
nc:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
  ptr addrspace(1) %a, ptr %la)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
  ptr addrspace(1) %b, ptr %lb)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
  ptr addrspace(1) %a, ptr %la2)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
  ptr addrspace(1) %c, ptr %lc)
  call void @sink(ptr addrspace(1) %c)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
  ptr addrspace(1) %c, ptr %lc)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
  ptr addrspace(1) %a, ptr %la2)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
  ptr addrspace(1) %b, ptr %lb)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
  ptr addrspace(1) %a, ptr %la)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_reentrant_interleaved_cascade
; The four re-emitted monitorenters must appear in strictly increasing lock
; depth: a@0 (la), b@1 (lb), a@2 (la2, re-entrant on the SAME object as la),
; c@3 (lc). Re-emitting each VO's locks together per-effect would produce an
; out-of-order sequence (e.g. lb, la, la2, lc = depths 1,0,2,3), violating
; the lightweight-lock thread-stack contract.
; CHECK: monitorenter_with_lightweight_lock(ptr addrspace(1) %[[MATA:.*]], ptr %la)
; CHECK: monitorenter_with_lightweight_lock(ptr addrspace(1) %[[MATB:.*]], ptr %lb)
; CHECK: monitorenter_with_lightweight_lock(ptr addrspace(1) %[[MATA]], ptr %la2)
; CHECK: monitorenter_with_lightweight_lock(ptr addrspace(1) %[[MATC:.*]], ptr %lc)
; CHECK: call void @sink(ptr addrspace(1) %[[MATC]])

!java-method-compilation = !{}
