; RUN: opt -passes='safepoint-poll-elimination,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -jeandle-loop-strip-mining-iter=0 -S < %s 2>&1 | FileCheck %s

; All loops satisfy the coverage invariant after elimination. The first two are
; int counted loops: with strip mining off they lose their polls (counted loops
; are poll-free, C2 counted_loop), but stay covered — the verifier accepts a
; counted loop as having a finite time-to-safepoint (the IV terminates within
; its type range). The multi-latch loop is not counted and keeps a poll on each
; backedge. The verifier must stay silent.

declare hotspotcc void @jeandle.safepoint_poll()

define void @covered_by_poll(i32 %n) "java-method" gc "safepoint-in-loop-example" {
entry:
  br label %loop.header

loop.header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop.header ]
  call hotspotcc void @jeandle.safepoint_poll()
  %iv.next = add nsw i32 %iv, 1
  %exit.cond = icmp slt i32 %iv.next, %n
  br i1 %exit.cond, label %loop.header, label %exit

exit:
  ret void
}

define void @covered_by_bound(ptr %a) "java-method" gc "safepoint-in-loop-example" {
entry:
  br label %loop.header

loop.header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop.header ]
  call hotspotcc void @jeandle.safepoint_poll()
  %p = getelementptr inbounds i32, ptr %a, i32 %iv
  store i32 0, ptr %p
  %iv.next = add nuw nsw i32 %iv, 1
  %exit.cond = icmp slt i32 %iv.next, 100
  br i1 %exit.cond, label %loop.header, label %exit

exit:
  ret void
}

define void @multi_latch_covered(i32 %n, i1 %choose) "java-method" gc "safepoint-in-loop-example" {
entry:
  br label %loop.header

loop.header:
  %iv = phi i32 [ 0, %entry ], [ %iv.a, %latch.a ], [ %iv.b, %latch.b ]
  %exit.cond = icmp slt i32 %iv, %n
  br i1 %exit.cond, label %body, label %exit

body:
  br i1 %choose, label %latch.a, label %latch.b

latch.a:
  %iv.a = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll()
  br label %loop.header

latch.b:
  %iv.b = add i32 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll()
  br label %loop.header

exit:
  ret void
}

define void @disjoint_paths_covered(i1 %choose, i1 %keep_going) "java-method" gc "safepoint-in-loop-example" {
entry:
  br label %loop.header

loop.header:
  br i1 %choose, label %path.a, label %path.b

path.a:
  call hotspotcc void @jeandle.safepoint_poll()
  br label %loop.latch

path.b:
  call hotspotcc void @jeandle.safepoint_poll()
  br label %loop.latch

loop.latch:
  br i1 %keep_going, label %loop.header, label %exit

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-NOT: SafepointCoverageVerifier:
; CHECK-LABEL: @covered_by_poll(
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll
; CHECK-LABEL: @covered_by_bound(
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll
; CHECK-LABEL: @multi_latch_covered(
; CHECK-COUNT-2: call hotspotcc void @jeandle.safepoint_poll()
; CHECK-LABEL: @disjoint_paths_covered(
; CHECK-COUNT-2: call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NOT: SafepointCoverageVerifier:
