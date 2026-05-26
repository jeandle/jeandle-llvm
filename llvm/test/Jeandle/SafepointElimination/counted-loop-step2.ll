; RUN: opt -passes=safepoint-elimination -S < %s | FileCheck %s

; for (int i = 0; i < n; i += 2) — non-unit stride.
; Counter is i32 with nsw step, eligible for the i32-no-wrap fast path.

declare hotspotcc void @jeandle.safepoint_poll()

define void @step_two(i32 %n) gc "step-two" {
entry:
  %cmp = icmp sgt i32 %n, 0
  br i1 %cmp, label %loop.header, label %exit

loop.header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop.latch ]
  %exit.cond = icmp slt i32 %iv, %n
  br i1 %exit.cond, label %loop.body, label %exit

loop.body:
  call hotspotcc void @jeandle.safepoint_poll()
  br label %loop.latch

loop.latch:
  %iv.next = add nsw i32 %iv, 2
  br label %loop.header

exit:
  call hotspotcc void @jeandle.safepoint_poll()
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @step_two(
; CHECK-NOT:   call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       {{^exit:}}
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    ret void
