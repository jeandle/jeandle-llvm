; RUN: opt -passes='loop-simplify,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s
; RUN: opt -passes='loop-simplify,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' -jeandle-verify-safepoint-coverage=fatal -disable-output < %s

; Pinning test for the strip-mining refactor (review §5.E.3). A latch-tested
; (do-while) source loop yields a post-tested outer loop: the outer latch
; re-tests the continue predicate, and the relocated poll must sit between that
; test and the conditional back-edge branch. relocatePollToOuterLatch inserts
; the cloned poll immediately before the outer latch's terminator, so a
; regression that moves the poll above outer.cond (or after the branch) surfaces
; here. The reduction %sum is also lifted, exercising buildOuterLatch ordering.

declare hotspotcc void @jeandle.safepoint_poll()

define i64 @post_tested(i64 noundef %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %sum = phi i64 [ 0, %entry ], [ %sum.next, %latch ]
  br label %latch

latch:
  %sum.next = add i64 %sum, %iv
  %iv.next = add nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %sum.next, i64 %iv.next) ]
  %cond = icmp slt i64 %iv.next, %n
  br i1 %cond, label %header, label %exit

exit:
  %res = phi i64 [ %sum.next, %latch ]
  ret i64 %res
}

!java-method-compilation = !{}

; CHECK-LABEL: @post_tested(
; Outer latch opens with the batch-boundary phi, then the continue test, then
; the relocated poll, then the conditional back-edge branch.
; CHECK: outer.latch:
; CHECK-NEXT: %outer.iv.next = phi
; CHECK: %outer.cond = icmp
; CHECK: call hotspotcc void @jeandle.safepoint_poll() #[[POLLATTR:[0-9]+]]
; CHECK: br i1 %outer.cond, label %{{.*}}.outer, label %exit
; CHECK: attributes #[[POLLATTR]] = { "jeandle.strip-mined-poll" }
