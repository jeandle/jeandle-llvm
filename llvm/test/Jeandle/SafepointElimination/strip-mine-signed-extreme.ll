; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' -jeandle-verify-safepoint-coverage=fatal -disable-output < %s
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>' -S < %s | FileCheck %s

; Extreme signed IV range: the recurrence starts at INT_MIN and runs toward
; INT_MAX. The per-batch residual-distance clamp subtracts Limit - OuterIV in a
; 2*BW wide type, which is the only thing keeping that subtraction from
; overflowing (in i32, (INT_MAX-1) - INT_MIN does not fit). This pins the wide
; form and confirms the coverage verifier still accepts the nest (no miscompile
; that would leave a backedge uncovered).

declare hotspotcc void @jeandle.safepoint_poll()

define void @extreme_range() "java-method" {
entry:
  br label %header

header:
  %iv = phi i32 [ -2147483648, %entry ], [ %iv.next, %latch ]
  %cond = icmp slt i32 %iv, 2147483646
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add nsw i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

!java-method-compilation = !{}

; The wide subtraction must be in i64 (2x the i32 IV width), and the IV-type
; limit is a non-overflowing add nsw. No signed saturating intrinsic is used.
; CHECK: %outer.batch.dist = sub nsw i64
; CHECK: call i64 @llvm.smin.i64
; CHECK: %outer.inner.limit = add nsw i32 %outer.iv, %outer.batch.chunk
; CHECK-NOT: sadd.sat
; CHECK-NOT: ssub.sat
