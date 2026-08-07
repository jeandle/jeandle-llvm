; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' \
; RUN:   -jeandle-loop-strip-mining-iter=1000 -S < %s | FileCheck %s

declare hotspotcc void @jeandle.safepoint_poll()

; LoopStripMiningIter counts actual iterations. A max backedge count of 999 is
; exactly 1000 iterations and is within budget.
define void @exactly_1000_iterations() "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop ]
  %iv.next = add nuw nsw i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %continue = icmp ult i32 %iv.next, 1000
  br i1 %continue, label %loop, label %exit
exit:
  ret void
}

; CHECK-LABEL: @exactly_1000_iterations(
; CHECK-NOT:   .outer
; CHECK-NOT:   call hotspotcc void @jeandle.safepoint_poll()

; A max backedge count of 1000 means 1001 iterations and exceeds the budget.
; It must be strip-mined instead of losing its poll as a short loop.
define void @iterations_1001() "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop ]
  %iv.next = add nuw nsw i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %continue = icmp ult i32 %iv.next, 1001
  br i1 %continue, label %loop, label %exit
exit:
  ret void
}

; CHECK-LABEL: @iterations_1001(
; CHECK:       loop.outer:
; CHECK:       loop.outer.latch:
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()

!java-method-compilation = !{}
