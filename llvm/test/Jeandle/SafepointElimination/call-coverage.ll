; RUN: opt -jeandle-loop-strip-mining-iter=0 -passes='safepoint-poll-elimination,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -S < %s | FileCheck %s

; A guaranteed-safepoint call (a Java invoke) on the latch's dominator spine
; covers the loop: the call dominates the latch, so it runs on every iteration
; and reaches a VM safepoint without a poll. analyzeLoop records the latch poll
; as the keep-one keeper but keeps walking the spine past it, finds the call
; (site A), and marks the loop HasSfpt; deleteLoopPolls then deletes ALL of the
; loop's deleteable polls (C2 _has_call/_has_sfpt ⇒ keep_one=false). The body
; call itself survives (deopt calls are never deleted), and the coverage
; verifier certifies the now poll-free loop.

declare hotspotcc void @jeandle.safepoint_poll()
declare hotspotcc void @java_method()

define void @spine_call_covers_loop(i64 %n) "java-method" {
entry:
  br label %loop.header

loop.header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %loop.latch ]
  call hotspotcc void @java_method() [ "deopt"(i64 %iv) ]
  %iv.next = add i64 %iv, 1
  br label %loop.latch

loop.latch:
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  %cond = icmp slt i64 %iv.next, %n
  br i1 %cond, label %loop.header, label %exit

exit:
  ret void
}

; A call in a conditional arm does NOT dominate the latch: a backedge path can
; bypass it, so it is not coverage and the loop keeps its poll.
define void @conditional_arm_call_not_coverage(i64 %n, i1 %f) "java-method" {
entry:
  br label %loop.header

loop.header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %loop.latch ]
  br i1 %f, label %arm, label %loop.latch

arm:
  call hotspotcc void @java_method() [ "deopt"(i64 %iv) ]
  br label %loop.latch

loop.latch:
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  %cond = icmp slt i64 %iv.next, %n
  br i1 %cond, label %loop.header, label %exit

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @spine_call_covers_loop(
; CHECK:       call hotspotcc void @java_method()
; CHECK-NOT:   call hotspotcc void @jeandle.safepoint_poll()
; CHECK-LABEL: @conditional_arm_call_not_coverage(
; CHECK:       call hotspotcc void @java_method()
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
