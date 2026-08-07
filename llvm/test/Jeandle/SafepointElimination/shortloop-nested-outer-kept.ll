; RUN: opt -passes=safepoint-poll-elimination -jeandle-loop-strip-mining-iter=0 -S < %s | FileCheck %s

; Both the inner and outer loops are int counted, so with strip mining off both
; lose their polls (C2 counted_loop applies to every int counted loop, not only
; the innermost): each terminates within its IV's type range, so each has a
; finite time-to-safepoint on its own.

declare hotspotcc void @jeandle.safepoint_poll()

define void @nested_outer(i32 %m) "java-method" gc "safepoint-in-loop-example" {
entry:
  br label %outer.header

outer.header:
  %i = phi i32 [ 0, %entry ], [ %i.next, %outer.latch ]
  br label %inner.header

inner.header:
  %j = phi i32 [ 0, %outer.header ], [ %j.next, %inner.header ]
  call hotspotcc void @jeandle.safepoint_poll()
  %j.next = add nsw i32 %j, 1
  %inner.cond = icmp slt i32 %j.next, %m
  br i1 %inner.cond, label %inner.header, label %outer.latch

outer.latch:
  call hotspotcc void @jeandle.safepoint_poll()
  %i.next = add nuw nsw i32 %i, 1
  %outer.cond = icmp slt i32 %i.next, 10
  br i1 %outer.cond, label %outer.header, label %exit

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @nested_outer(
; CHECK-NOT:   call hotspotcc void @jeandle.safepoint_poll
