; RUN: opt -passes=safepoint-elimination -S < %s | FileCheck %s

; for (int i = 10; i < n; ++i) — non-zero IV start.
; Counter is i32 with nsw step, eligible for the i32-no-wrap fast path.

declare hotspotcc void @jeandle.safepoint_poll()

define void @nonzero_init(i32 %n) gc "nonzero-init" {
entry:
  %cmp = icmp sgt i32 %n, 10
  br i1 %cmp, label %loop.header, label %exit

loop.header:
  %iv = phi i32 [ 10, %entry ], [ %iv.next, %loop.latch ]
  %exit.cond = icmp slt i32 %iv, %n
  br i1 %exit.cond, label %loop.body, label %exit

loop.body:
  call hotspotcc void @jeandle.safepoint_poll()
  br label %loop.latch

loop.latch:
  %iv.next = add nsw i32 %iv, 1
  br label %loop.header

exit:
  call hotspotcc void @jeandle.safepoint_poll()
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @nonzero_init(
; CHECK-NOT:   call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       {{^exit:}}
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    ret void
