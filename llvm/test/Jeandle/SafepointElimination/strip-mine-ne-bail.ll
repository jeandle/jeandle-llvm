; RUN: opt -passes='safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s

; `i != limit` is only converted to a relational counted loop for unit strides
; and a proven start/limit order. Otherwise the original poll stays in place.

declare hotspotcc void @jeandle.safepoint_poll()

define void @ne_stride_two_bails(i64 %n) "java-method" {
entry:
  %entry.guard = icmp sle i64 0, %n
  br i1 %entry.guard, label %loop.preheader, label %return

loop.preheader:
  br label %header

header:
  %iv = phi i64 [ 0, %loop.preheader ], [ %iv.next, %latch ]
  %cond = icmp ne i64 %iv, %n
  br i1 %cond, label %body, label %loop.exit

body:
  %iv.next = add nsw i64 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

loop.exit:
  br label %return

return:
  ret void
}

; CHECK-LABEL: @ne_stride_two_bails(
; CHECK-NOT:   .outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NOT:   jeandle.strip-mined-poll


define void @ne_without_order_guard_bails(i64 %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp ne i64 %iv, %n
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

; CHECK-LABEL: @ne_without_order_guard_bails(
; CHECK-NOT:   .outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NOT:   jeandle.strip-mined-poll

define void @latch_ne_without_order_guard_bails(i64 %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  br label %latch

latch:
  %iv.next = add nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  %cond = icmp ne i64 %iv.next, %n
  br i1 %cond, label %header, label %exit

exit:
  ret void
}

; CHECK-LABEL: @latch_ne_without_order_guard_bails(
; CHECK-NOT:   .outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NOT:   jeandle.strip-mined-poll

!java-method-compilation = !{}
