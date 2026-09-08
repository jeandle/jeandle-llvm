; RUN: opt -passes='loop-simplify,lcssa,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-loop-strip-mining-iter=8 \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -verify-each -S < %s \
; RUN:   | FileCheck %s

; IndVarSimplify may rewrite a latch comparison from the next IV to the current
; IV and an adjusted bound. The current-IV compare is still a canonical affine
; induction; strip mining must clamp that compare while resuming the outer loop
; from iv.next.

declare hotspotcc void @jeandle.safepoint_poll()

define i32 @current_iv_step2() "java-method" {
entry:
  br label %loop

loop:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop ]
  %iv.next = add nuw nsw i32 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp ugt i32 %iv, 39
  br i1 %done, label %exit, label %loop

exit:
  %result = phi i32 [ %iv.next, %loop ]
  ret i32 %result
}

; A current-IV equality exit is a normalized NE counted loop. Unlike the
; next-IV form, start == limit is valid: the do-while executes once and exits.
; Proving start <= smax(limit, 0) must therefore be enough to strip-mine it.
define i32 @current_iv_eq_smax(i32 %raw.limit) "java-method" {
entry:
  %limit = call i32 @llvm.smax.i32(i32 %raw.limit, i32 0)
  br label %loop.eq

loop.eq:
  %iv.eq = phi i32 [ 0, %entry ], [ %iv.next.eq, %loop.eq ]
  %iv.next.eq = add nuw nsw i32 %iv.eq, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next.eq) ]
  %done.eq = icmp eq i32 %iv.eq, %limit
  br i1 %done.eq, label %exit.eq, label %loop.eq

exit.eq:
  %result.eq = phi i32 [ %iv.next.eq, %loop.eq ]
  ret i32 %result.eq
}

declare i32 @llvm.smax.i32(i32, i32)

!java-method-compilation = !{}

; CHECK-LABEL: @current_iv_step2(
; CHECK:       %done = icmp ugt i32 %iv, %outer.inner.limit
; CHECK:       loop.outer:
; CHECK:       %outer.batch.end = call i32 @llvm.uadd.sat.i32(i32 %outer.iv, i32 12)
; CHECK:       %outer.inner.limit = select i1 %outer.cap.cond, i32 %outer.batch.end, i32 39
; CHECK:       loop.outer.latch:
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() #[[POLL:[0-9]+]] [ "deopt"(i32 %outer.iv.next) ]
;
; CHECK-LABEL: @current_iv_eq_smax(
; CHECK:       loop.eq.outer:
; CHECK:       loop.eq.outer.latch:
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() #[[POLL]] [ "deopt"(i32 %outer.iv.next) ]
; CHECK:       attributes #[[POLL]] = { "jeandle.strip-mined-poll" }
