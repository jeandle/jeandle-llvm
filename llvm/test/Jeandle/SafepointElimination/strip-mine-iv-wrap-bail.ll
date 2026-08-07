; RUN: opt -passes='safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s

; |step| > 1 without a provable no-wrap fact can step past the type extreme,
; wrap to the other side, and then run a huge poll-free span before reaching
; the clamped inner limit. The transform must bail and keep the poll.

declare hotspotcc void @jeandle.safepoint_poll()

define void @wrap(i64 %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp ult i64 %iv, %n
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add i64 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

define void @wrap_down(i64 %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 1, %entry ], [ %iv.next, %latch ]
  %cond = icmp sgt i64 %iv, %n
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add i64 %iv, -2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @wrap(
; CHECK-NOT:   outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]

; CHECK-LABEL: @wrap_down(
; CHECK-NOT:   outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
