; RUN: opt -jeandle-loop-strip-mining-iter=0 -passes='safepoint-poll-elimination,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -S < %s | FileCheck %s

; The inner loop has a deopt-bundle call every iteration, so it is covered. The
; inner header dominates the outer latch, so the outer loop reaches that call
; every iteration too: the outer's own back-edge poll is redundant and is
; removed, while the inner loop's call stays as coverage for the whole nest.

declare hotspotcc void @jeandle.safepoint_poll()
declare hotspotcc void @java_method()

define void @subloop_call_covers_outer(i64 %n, i64 %m) "java-method" {
entry:
  br label %outer.header

outer.header:
  %i = phi i64 [ 0, %entry ], [ %i.next, %outer.latch ]
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %i) ]
  br label %inner.header

inner.header:
  %j = phi i64 [ 0, %outer.header ], [ %j.next, %inner.latch ]
  call hotspotcc void @java_method() [ "deopt"(i64 %j) ]
  %j.next = add i64 %j, 1
  %cond = icmp slt i64 %j.next, %m
  br i1 %cond, label %inner.latch, label %outer.latch

inner.latch:
  br label %inner.header

outer.latch:
  %i.next = add i64 %i, 1
  %cond2 = icmp slt i64 %i.next, %n
  br i1 %cond2, label %outer.header, label %exit

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @subloop_call_covers_outer(
; CHECK-NOT: call hotspotcc void @jeandle.safepoint_poll
; CHECK:     call hotspotcc void @java_method() [ "deopt"(i64 %j) ]
