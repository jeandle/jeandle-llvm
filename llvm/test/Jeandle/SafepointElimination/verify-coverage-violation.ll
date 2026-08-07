; RUN: opt -passes='verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=warn -S < %s 2>&1 | FileCheck %s
; RUN: not --crash opt -passes='verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -disable-output < %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=ABORT

; A loop with no poll that is NOT a counted loop violates the coverage
; invariant: a thread inside it can never reach a safepoint. @naked_loop exits
; on a loaded value (no induction variable), so it is not a counted loop and is
; not accepted as finite; the multi-latch loops have no single latch. In warn
; mode the verifier reports and keeps opt alive; in fatal mode it aborts.

declare hotspotcc void @jeandle.safepoint_poll()

define void @partially_covered_multi_latch(i64 %n, i1 %choose) "java-method" gc "safepoint-in-loop-example" {
entry:
  br label %partial.header

partial.header:
  %iv = phi i64 [ 0, %entry ], [ %iv.a, %latch.a ], [ %iv.b, %latch.b ]
  %exit.cond = icmp slt i64 %iv, %n
  br i1 %exit.cond, label %body, label %exit

body:
  br i1 %choose, label %latch.a, label %latch.b

latch.a:
  %iv.a = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll()
  br label %partial.header

latch.b:
  %iv.b = add i64 %iv, 2
  br label %partial.header

exit:
  ret void
}

define void @naked_multi_latch(i64 %n, i1 %choose) "java-method" gc "safepoint-in-loop-example" {
entry:
  br label %multi.header

multi.header:
  %iv = phi i64 [ 0, %entry ], [ %iv.a, %latch.a ], [ %iv.b, %latch.b ]
  %exit.cond = icmp slt i64 %iv, %n
  br i1 %exit.cond, label %body, label %exit

body:
  br i1 %choose, label %latch.a, label %latch.b

latch.a:
  %iv.a = add i64 %iv, 1
  br label %multi.header

latch.b:
  %iv.b = add i64 %iv, 2
  br label %multi.header

exit:
  ret void
}

define void @naked_loop(ptr %p) "java-method" gc "safepoint-in-loop-example" {
entry:
  br label %loop.header

loop.header:
  %v = load i32, ptr %p
  %exit.cond = icmp eq i32 %v, 0
  br i1 %exit.cond, label %loop.header, label %exit

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-DAG: SafepointCoverageVerifier: loop with header 'loop.header' in function 'naked_loop' has an uncovered backedge path and no provable trip bound
; CHECK-DAG: SafepointCoverageVerifier: loop with header 'multi.header' in function 'naked_multi_latch' has an uncovered backedge path and no provable trip bound
; CHECK-DAG: SafepointCoverageVerifier: loop with header 'partial.header' in function 'partially_covered_multi_latch' has an uncovered backedge path and no provable trip bound

; ABORT-DAG: SafepointCoverageVerifier: loop with header 'partial.header' in function 'partially_covered_multi_latch' has an uncovered backedge path and no provable trip bound
; ABORT: Jeandle safepoint coverage verification failed
