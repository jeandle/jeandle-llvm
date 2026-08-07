; RUN: opt -passes=safepoint-poll-elimination -jeandle-loop-strip-mining-iter=0 -S < %s \
; RUN:   | FileCheck %s

; With strip mining off (-jeandle-loop-strip-mining-iter=0), an int counted
; loop loses its poll (C2 counted_loop with LoopStripMiningIter == 0) regardless
; of its trip count: it terminates within the IV's type range, so its
; time-to-safepoint is finite even though the trip count (5000) is above the
; default budget (1000) — counted-loop deletion does not consult the budget.

declare hotspotcc void @jeandle.safepoint_poll()

define void @above_budget(ptr %a) "java-method" gc "safepoint-in-loop-example" {
entry:
  br label %loop.header

loop.header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop.header ]
  call hotspotcc void @jeandle.safepoint_poll()
  %p = getelementptr inbounds i32, ptr %a, i32 %iv
  store i32 0, ptr %p
  %iv.next = add nuw nsw i32 %iv, 1
  %exit.cond = icmp slt i32 %iv.next, 5000
  br i1 %exit.cond, label %loop.header, label %exit

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @above_budget(
; CHECK-NOT: call hotspotcc void @jeandle.safepoint_poll
