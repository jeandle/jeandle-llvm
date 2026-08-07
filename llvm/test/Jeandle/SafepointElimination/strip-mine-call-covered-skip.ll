; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -S < %s | FileCheck %s

; A loop that already reaches a guaranteed-safepoint call on every iteration
; gains nothing from strip mining: C2 declines to strip-mine loops with calls
; (is_counted_loop's !loop->_has_call) and just deletes the back-edge poll.
; Do the same — skip the wrap and let the call provide coverage — instead of
; paying for an outer loop whose poll is redundant.

declare hotspotcc void @jeandle.safepoint_poll()
declare void @some.java.call()
declare ptr @jeandle.new_instance(ptr) "jeandle.not-guaranteed-safepoint"

; The call precedes the poll on the latch-dominating path, so the relocation
; hazard walk lets the loop be mined today. It must be skipped instead, and
; the poll deleted as call-covered.
define void @call_before_poll_not_mined(i64 %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp slt i64 %iv, %n
  br i1 %cond, label %body, label %exit

body:
  call void @some.java.call() [ "deopt"(i64 %iv) ]
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

; CHECK-LABEL: @call_before_poll_not_mined(
; CHECK-NOT:     .outer
; CHECK:         call void @some.java.call()
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll()
; CHECK:         ret void

; A guaranteed call after the poll already blocks relocation as a hazard; the
; poll is deleted as call-covered either way.
define void @call_after_poll_not_mined(i64 %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp slt i64 %iv, %n
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  call void @some.java.call() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

; CHECK-LABEL: @call_after_poll_not_mined(
; CHECK-NOT:     .outer
; CHECK:         call void @some.java.call()
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll()
; CHECK:         ret void

; An allocation fast path is NOT a guaranteed safepoint: the loop still needs
; bounded coverage, so it is strip-mined as before.
define void @alloc_call_still_mined(i64 %n, ptr %class) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp slt i64 %iv, %n
  br i1 %cond, label %body, label %exit

body:
  %obj = call ptr @jeandle.new_instance(ptr %class) [ "deopt"(i64 %iv) ]
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

; CHECK-LABEL: @alloc_call_still_mined(
; CHECK:         .outer
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}}
; CHECK:       attributes #{{[0-9]+}} = { "jeandle.strip-mined-poll" }
