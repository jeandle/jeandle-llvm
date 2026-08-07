; RUN: opt -passes='loop-simplify,safepoint-poll-elimination' \
; RUN:   -jeandle-loop-strip-mining-iter=0 -S < %s | FileCheck %s

; With strip mining off, an int counted loop loses all of its polls (C2
; counted_loop with LoopStripMiningIter == 0) regardless of its trip count: the
; loop terminates within the IV's type range, so its time-to-safepoint is
; finite. All three loops below are int counted — on the chunk budget boundary,
; past it, and bounded by a runtime value — and all lose their polls.

declare hotspotcc void @jeandle.safepoint_poll()

define void @const_at_budget_deleted(ptr %a) "java-method" gc "safepoint-in-loop-example" {
entry:
  br label %loop.header

loop.header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop.header ]
  call hotspotcc void @jeandle.safepoint_poll()
  %p = getelementptr inbounds i32, ptr %a, i32 %iv
  store i32 0, ptr %p
  %iv.next = add nuw nsw i32 %iv, 1
  %exit.cond = icmp slt i32 %iv.next, 1001
  br i1 %exit.cond, label %loop.header, label %exit

exit:
  ret void
}

define void @const_above_budget_kept(ptr %a) "java-method" gc "safepoint-in-loop-example" {
entry:
  br label %loop.header

loop.header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop.header ]
  call hotspotcc void @jeandle.safepoint_poll()
  %p = getelementptr inbounds i32, ptr %a, i32 %iv
  store i32 0, ptr %p
  %iv.next = add nuw nsw i32 %iv, 1
  %exit.cond = icmp slt i32 %iv.next, 1002
  br i1 %exit.cond, label %loop.header, label %exit

exit:
  ret void
}

define void @param_bound_kept(i32 %n) "java-method" gc "safepoint-in-loop-example" {
entry:
  %cmp = icmp sgt i32 %n, 0
  br i1 %cmp, label %loop.header, label %exit

loop.header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop.header ]
  call hotspotcc void @jeandle.safepoint_poll()
  %iv.next = add nsw i32 %iv, 1
  %exit.cond = icmp slt i32 %iv.next, %n
  br i1 %exit.cond, label %loop.header, label %exit

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @const_at_budget_deleted(
; CHECK-NOT:   call hotspotcc void @jeandle.safepoint_poll

; CHECK-LABEL: @const_above_budget_kept(
; CHECK-NOT:   call hotspotcc void @jeandle.safepoint_poll

; CHECK-LABEL: @param_bound_kept(
; CHECK-NOT:   call hotspotcc void @jeandle.safepoint_poll
