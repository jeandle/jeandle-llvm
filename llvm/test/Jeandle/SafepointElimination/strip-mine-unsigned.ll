; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal \
; RUN:   -disable-output < %s

; Canonical unsigned counted loop: SCEV can prove the step-1 recurrence does
; not unsigned-wrap, so strip mining fires and uses the unsigned saturating add.

declare hotspotcc void @jeandle.safepoint_poll()

define void @uloop(i64 noundef %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp ult i64 %iv, %n
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

define void @udown(i64 noundef %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ %n, %entry ], [ %iv.next, %latch ]
  %cond = icmp ugt i64 %iv, 0
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add i64 %iv, -1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @uloop(
; CHECK:       %outer.cond = icmp ult i64 %outer.iv, %n
; CHECK:       %outer.batch.end = call i64 @llvm.uadd.sat.i64(i64 %outer.iv, i64 1000)
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()

; CHECK-LABEL: @udown(
; CHECK:       %outer.cond = icmp ugt i64 %outer.iv, 0
; CHECK:       %outer.batch.end = call i64 @llvm.usub.sat.i64(i64 %outer.iv, i64 1000)
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
