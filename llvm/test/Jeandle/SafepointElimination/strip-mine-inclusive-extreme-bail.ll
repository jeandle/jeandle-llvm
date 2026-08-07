; RUN: opt -passes='safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s

; Inclusive predicate (i <= n) with an unconstrained limit. If n == INT64_MAX,
; the saturating batch-end (outer.iv + 999, saturated) pins the clamped inner
; limit to INT64_MAX, and the inner test `i <= INT64_MAX` can never fail: the
; poll-free inner loop would spin forever and hang GC. The original loop is also
; infinite for that n, but it polls every iteration and keeps GC live. SCEV
; can't prove n < INT64_MAX for a bare parameter, so the transform declines and
; keeps the poll. (Contrast strip-mine-inclusive-sle.ll, where a mask bounds n.)

declare hotspotcc void @jeandle.safepoint_poll()

define void @loop(i64 %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp sle i64 %iv, %n
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @loop(
; CHECK-NOT:   outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
