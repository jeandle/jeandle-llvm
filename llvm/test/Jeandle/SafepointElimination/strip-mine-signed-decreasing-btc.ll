; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' -jeandle-verify-safepoint-coverage=fatal -disable-output < %s
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>' -S < %s | FileCheck %s --check-prefix=IR
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,print<scalar-evolution>' -disable-output < %s 2>&1 | FileCheck %s --check-prefix=SCEV

; Decreasing counterpart of strip-mine-signed-btc-scev.ll: `for (i = n; i > 0;
; i--)`. The clamp uses the residual-distance chunk in a 2*BW wide type (never
; ssub_sat), so SCEV must still compute the inner loop's backedge-taken count.

declare hotspotcc void @jeandle.safepoint_poll()

define void @countdown(i64 noundef %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ %n, %entry ], [ %iv.next, %latch ]
  %cond = icmp sgt i64 %iv, 0
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add nsw i64 %iv, -1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

!java-method-compilation = !{}

; IR: %outer.batch.dist = sub nsw i128
; IR: @llvm.smin.i128
; IR: %outer.inner.limit = sub nsw i64 %outer.iv, %outer.batch.chunk
; IR-NOT: sadd.sat
; IR-NOT: ssub.sat

; The inner loop's backedge-taken count is a computable symbolic expression
; built from the clamped chunk — NOT CouldNotCompute.
; SCEV: backedge-taken count is {{.*}}smin
; SCEV-NOT: ***COULD NOT COMPUTE***
; SCEV: Unpredictable backedge-taken count
