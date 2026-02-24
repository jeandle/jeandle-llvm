; RUN: opt -passes=safepoint-elimination -S < %s | FileCheck %s

declare hotspotcc void @jeandle.safepoint_poll()

; Test non-counted loop (variable step)
; safepoint should NOT be eliminated

define void @non_counted_loop_variable_step(i32 %n) gc "safepoint-in-non-leaf-counted-loop-example" {
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
  %inner_iv.next = add i32 %inner_iv, 1
  br label %inner_loop.header

inner_loop.exit:
  br label %loop.latch

loop.latch:
  %iv.next = add i32 %iv, 1
  br label %loop.header

exit:
  ; Safepoint before ret should NOT be eliminated
  call hotspotcc void @jeandle.safepoint_poll()
  ret void
}

; CHECK-LABEL: @non_counted_loop_variable_step(
; CHECK: loop.body:
; The safepoint should remain in the loop body since the outer loop has nested sub-loops
; CHECK-NEXT: call hotspotcc void @jeandle.safepoint_poll()
; CHECK: inner_loop.body:
; The safepoint in the inner loop remains because the pass only processes top-level loops
; CHECK-NEXT: call hotspotcc void @jeandle.safepoint_poll()
; CHECK: exit:
; The safepoint poll before return should not be eliminated
; CHECK: call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT: ret void
