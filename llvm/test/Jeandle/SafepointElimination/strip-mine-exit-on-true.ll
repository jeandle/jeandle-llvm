; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal \
; RUN:   -disable-output < %s

; Exit-on-true shape: `icmp sge i, n; br %cond, exit, body`. The continue
; predicate is the inverse (slt), so direction reasoning and the outer-loop
; exit test are built off "continue", matching the canonical exit-on-false
; loop. The outer condition is slt, not sge.

declare hotspotcc void @jeandle.safepoint_poll()

define void @loop(i64 noundef %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp sge i64 %iv, %n
  br i1 %cond, label %exit, label %body

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
; CHECK:         %outer.cond = icmp slt i64 %outer.iv, %n
; CHECK:         %outer.batch.dist = sub nsw i128
; CHECK:         call i128 @llvm.smin.i128
; CHECK:         %outer.inner.limit = add nsw i64 %outer.iv, %outer.batch.chunk
; CHECK:         call hotspotcc void @jeandle.safepoint_poll()
