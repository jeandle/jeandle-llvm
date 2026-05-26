; RUN: opt -passes=safepoint-elimination -S < %s | FileCheck %s

; for (long i = 0; i < 1000; ++i) — i64 IV but a constant, small bound.
; SCEV's constant max-backedge-taken count is finite (= 1000) and fits within
; -jeandle-short-loop-max-iter, so the back-edge poll is removed without
; relying on the i32 fallback.

declare hotspotcc void @jeandle.safepoint_poll()

define void @i64_bounded() gc "i64-bounded" {
entry:
  br label %loop.header

loop.header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %loop.latch ]
  %exit.cond = icmp slt i64 %iv, 1000
  br i1 %exit.cond, label %loop.body, label %exit

loop.body:
  call hotspotcc void @jeandle.safepoint_poll()
  br label %loop.latch

loop.latch:
  %iv.next = add nsw i64 %iv, 1
  br label %loop.header

exit:
  call hotspotcc void @jeandle.safepoint_poll()
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @i64_bounded(
; CHECK-NOT:   call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       {{^exit:}}
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    ret void
