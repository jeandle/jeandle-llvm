; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Per-pred cascade with re-entrant interleaved locks, exercising the per-pred
; lock re-emit global depth sort.
;
; A forward field chain a.f = b, b.g = c (so per-pred materializing `a` cascades
; prerequisites `b` then `c`). `a`, `b`, `c` are distinct new_instance klasses
; (11111/22222/33333). The left branch acquires four real guard locks, while the
; right branch acquires four locks on the virtual objects. Both predecessors
; therefore reach the merge at CFG-derived depth 4. The differing lock state
; drives per-pred materialization of `a` (cascading `b`, `c`) on the right edge;
; all three effects share one escape point and form one cascade group. Separate
; exit blocks release each path's locks in reverse order, so every real exit is
; balanced.
;
; Cascade SeqNo order (field-prereq recursion): c (deepest prereq, lowest SeqNo)
; -> b -> a (tail, highest SeqNo). Per-effect emit would emit each effect's
; own Locks in SeqNo order: c's [c@3], b's [b@1], a's [a@0, a@2] => depths
; 3,1,0,2 — NOT strictly increasing, violating the lightweight-lock thread-stack
; contract. The group's locks are merged and globally depth-sorted, then
; emitted once from the tail (a): 0,1,2,3.
;
; One materialize commit per materialize point flattens every object's locks
; and lowers them globally depth-sorted.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @per_pred_cascade_interleaved_locks(
    i1 %c, ptr addrspace(1) %g0, ptr addrspace(1) %g1,
    ptr addrspace(1) %g2, ptr addrspace(1) %g3)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lg0 = alloca i64, align 8
  %lg1 = alloca i64, align 8
  %lg2 = alloca i64, align 8
  %lg3 = alloca i64, align 8
  %la0 = alloca i64, align 8
  %lb1 = alloca i64, align 8
  %la2 = alloca i64, align 8
  %lc3 = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 11111 to ptr), i32 32, i1 false)
           to label %na unwind label %u
na:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 22222 to ptr), i32 32, i1 false)
           to label %nb unwind label %u
nb:
  %c_obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 33333 to ptr), i32 32, i1 false)
           to label %fld unwind label %u
fld:
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic ptr addrspace(1) %b, ptr addrspace(1) %af unordered, align 8
  %bg = getelementptr inbounds i8, ptr addrspace(1) %b, i64 16
  store atomic ptr addrspace(1) %c_obj, ptr addrspace(1) %bg unordered, align 8
  br label %branch
branch:
  br i1 %c, label %left, label %right
left:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
              ptr addrspace(1) %g0, ptr %lg0)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
              ptr addrspace(1) %g1, ptr %lg1)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
              ptr addrspace(1) %g2, ptr %lg2)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
              ptr addrspace(1) %g3, ptr %lg3)
  br label %merge
right:
  tail call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
              ptr addrspace(1) %a, ptr %la0)
  tail call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
              ptr addrspace(1) %b, ptr %lb1)
  tail call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
              ptr addrspace(1) %a, ptr %la2)
  tail call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
              ptr addrspace(1) %c_obj, ptr %lc3)
  br label %merge
merge:
  call void @sink(ptr addrspace(1) %a)
  call void @sink(ptr addrspace(1) %b)
  call void @sink(ptr addrspace(1) %c_obj)
  br i1 %c, label %left.exit, label %right.exit
left.exit:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
              ptr addrspace(1) %g3, ptr %lg3)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
              ptr addrspace(1) %g2, ptr %lg2)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
              ptr addrspace(1) %g1, ptr %lg1)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
              ptr addrspace(1) %g0, ptr %lg0)
  ret void
right.exit:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
              ptr addrspace(1) %c_obj, ptr %lc3)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
              ptr addrspace(1) %a, ptr %la2)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
              ptr addrspace(1) %b, ptr %lb1)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
              ptr addrspace(1) %a, ptr %la0)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}

; CHECK-LABEL: define void @per_pred_cascade_interleaved_locks
; The four re-emitted monitorenters must appear in strictly increasing lock
; depth on the right materialization path: a@0 (la0), b@1 (lb1), a@2 (la2,
; re-entrant on the SAME object as la0), c@3 (lc3). Re-emitting each VO's
; locks together per-effect in SeqNo order (c@3, b@1, a@0,
; a@2 => depths 3,1,0,2) would violate the lightweight-lock thread-stack
; contract.
; Sequential CHECK is order-sensitive. Anchor it in the right-edge field replay
; so the left branch's original real-guard calls cannot satisfy these checks.
; CHECK: right:
; CHECK: %[[BG:[A-Za-z0-9._]+]] = getelementptr inbounds i8, ptr addrspace(1) %b, i64 16
; CHECK-NEXT: store atomic ptr addrspace(1) %c_obj, ptr addrspace(1) %[[BG]] unordered, align 8
; CHECK: %[[AF:[A-Za-z0-9._]+]] = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
; CHECK-NEXT: store atomic ptr addrspace(1) %b, ptr addrspace(1) %[[AF]] unordered, align 8
; The source calls are `tail call`; replay constructs fresh bare calls. Anchoring
; at the start of each line proves these are the replayed operations.
; CHECK: {{^  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock\(ptr addrspace\(1\) %a, ptr %la0\)}}
; CHECK: {{^  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock\(ptr addrspace\(1\) %b, ptr %lb1\)}}
; CHECK: {{^  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock\(ptr addrspace\(1\) %a, ptr %la2\)}}
; CHECK: {{^  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock\(ptr addrspace\(1\) %c_obj, ptr %lc3\)}}
; CHECK-NOT: poison
