; RUN: opt -passes='loop-simplify,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s
; RUN: opt -passes='loop-simplify,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' -jeandle-verify-safepoint-coverage=fatal -disable-output < %s

; Pinning test for the strip-mining refactor (review §5.E.3). A loop with two
; header recurrences besides the IV must lift every recurrence to the outer loop
; in a stable order: the outer header carries outer.iv followed by one *.outer
; phi per recurrence, and the outer latch carries outer.iv.next followed by one
; *.outer.next phi per recurrence. A regression in createOuterSkeleton /
; buildOuterLatch that drops or reorders a lifted recurrence surfaces here.

declare hotspotcc void @jeandle.safepoint_poll()

define i64 @multi(i64 noundef %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %r1 = phi i64 [ 0, %entry ], [ %r1.next, %latch ]
  %r2 = phi i64 [ 0, %entry ], [ %r2.next, %latch ]
  %cond = icmp slt i64 %iv, %n
  br i1 %cond, label %body, label %exit

body:
  %r1.next = add i64 %r1, %iv
  %r2.next = add i64 %r2, %r1
  %iv.next = add nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %r1.next, i64 %r2.next, i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  %res = phi i64 [ %r1, %header ]
  ret i64 %res
}

!java-method-compilation = !{}

; CHECK-LABEL: @multi(
; Outer header: the outer IV phi immediately followed by both lifted-reduction
; phis (consecutive), then the outer continue test.
; CHECK: %outer.iv = phi
; CHECK-NEXT: %{{.*}}.outer = phi
; CHECK-NEXT: %{{.*}}.outer = phi
; CHECK-NEXT: %outer.cond = icmp
; Outer latch: the outer IV next-phi immediately followed by both lifted-
; reduction next-phis (consecutive).
; CHECK: %outer.iv.next = phi
; CHECK-NEXT: %{{.*}}.outer.next = phi
; CHECK-NEXT: %{{.*}}.outer.next = phi
