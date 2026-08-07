; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' -jeandle-verify-safepoint-coverage=fatal -disable-output < %s
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>' -S < %s | FileCheck %s --check-prefix=IR
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,print<scalar-evolution>' -disable-output < %s 2>&1 | FileCheck %s --check-prefix=SCEV

; The canonical signed Java counted loop `for (int/long i = 0; i < n; i++)`.
;
; Regression guard for review finding 5.C.1: the per-batch clamp used to emit
; sadd_sat, which ScalarEvolution does NOT model, so the inner (poll-free) loop's
; backedge-taken count came back as ***COULD NOT COMPUTE*** — defeating the
; unroll/vectorize that strip mining exists to enable. The clamp now uses a
; residual-distance chunk (smax/smin/sub over a 2*BW wide type), every op of
; which SCEV models, so the inner trip count must stay analyzable.

declare hotspotcc void @jeandle.safepoint_poll()

define void @count(i64 noundef %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp slt i64 %iv, %n
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

!java-method-compilation = !{}

; The signed clamp uses the wide residual-distance form, never sadd_sat/ssub_sat.
; IR: %outer.batch.dist = sub nsw i128
; IR: @llvm.smax.i128
; IR: @llvm.smin.i128
; IR: %outer.inner.limit = add nsw i64 %outer.iv, %outer.batch.chunk
; IR-NOT: sadd.sat
; IR-NOT: ssub.sat

; The inner loop's backedge-taken count is a computable symbolic expression
; (built from smax/smin over the clamped chunk) — NOT CouldNotCompute. The outer
; loop is correctly Unpredictable (its trip count depends on %n).
; SCEV: backedge-taken count is {{.*}}smax{{.*}}smin
; SCEV-NOT: ***COULD NOT COMPUTE***
; SCEV: Unpredictable backedge-taken count
