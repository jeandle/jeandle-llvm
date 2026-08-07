; RUN: opt -passes='safepoint-poll-elimination<early>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-loop-strip-mining-iter=0 \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -S < %s | FileCheck %s

; An i32 induction used by one optional side exit does not make the whole loop
; finite. The bypass path can repeat forever, so the loop must retain a poll.

declare hotspotcc void @jeandle.safepoint_poll()

define void @optional_side_exit(i1 %bypass) "java-method" {
entry:
  br label %header

header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %latch ]
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv) ]
  %iv.next = add i32 %iv, 1
  br i1 %bypass, label %latch, label %check

check:
  %done = icmp eq i32 %iv.next, 10
  br i1 %done, label %exit, label %latch

latch:
  br label %header

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @optional_side_exit(
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
