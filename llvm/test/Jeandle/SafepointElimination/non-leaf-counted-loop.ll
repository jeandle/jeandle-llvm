; RUN: opt -passes=safepoint-elimination -S < %s | FileCheck %s

declare hotspotcc void @jeandle.safepoint_poll()

; Nested counted loops. With LoopInfo::getLoopsInPreorder(), the pass visits
; both the outer and the inner counted loop and removes the back-edge poll
; from each.

define void @nested_counted_loops(i32 %n) gc "nested-counted-loops-example" {
entry:
  %cmp = icmp sgt i32 %n, 0
  br i1 %cmp, label %loop.header, label %exit

loop.header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop.latch ]
  %exit.cond = icmp slt i32 %iv, %n
  br i1 %exit.cond, label %loop.body, label %exit

loop.body:
  call hotspotcc void @jeandle.safepoint_poll()
  br label %inner_loop.header

inner_loop.header:
  %inner_iv = phi i32 [ 0, %loop.body ], [ %inner_iv.next, %inner_loop.latch ]
  %inner_exit.cond = icmp slt i32 %inner_iv, %n
  br i1 %inner_exit.cond, label %inner_loop.body, label %inner_loop.exit

inner_loop.body:
  call hotspotcc void @jeandle.safepoint_poll()
  ; Some loop body work
  %val = load i32, ptr null
  br label %inner_loop.latch

inner_loop.latch:
  %inner_iv.next = add nsw i32 %inner_iv, 1
  br label %inner_loop.header

inner_loop.exit:
  br label %loop.latch

loop.latch:
  %iv.next = add nsw i32 %iv, 1
  br label %loop.header

exit:
  ; Safepoint before ret should NOT be eliminated
  call hotspotcc void @jeandle.safepoint_poll()
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @nested_counted_loops(
; Both the outer and the inner back-edge polls are removed; the only
; remaining safepoint is the one immediately before the function's ret.
; CHECK-NOT:   call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    ret void
