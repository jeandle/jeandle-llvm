; RUN: opt -passes=safepoint-elimination -jeandle-sp-elim-32bit-range=true -S < %s | FileCheck %s

; for (int i = n; i > 0; --i) — negative stride.
; Counter is i32 with nsw step, eligible for the i32-no-wrap fast path.

declare hotspotcc void @jeandle.safepoint_poll()

define void @neg_stride(i32 %n) gc "neg-stride" {
entry:
  %cmp = icmp sgt i32 %n, 0
  br i1 %cmp, label %loop.header, label %exit

loop.header:
  %iv = phi i32 [ %n, %entry ], [ %iv.next, %loop.latch ]
  %exit.cond = icmp sgt i32 %iv, 0
  br i1 %exit.cond, label %loop.body, label %exit

loop.body:
  call hotspotcc void @jeandle.safepoint_poll()
  br label %loop.latch

loop.latch:
  %iv.next = sub nsw i32 %iv, 1
  br label %loop.header

exit:
  call hotspotcc void @jeandle.safepoint_poll()
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @neg_stride(
; CHECK-NOT:   call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       {{^exit:}}
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    ret void
