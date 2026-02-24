; RUN: opt -passes=safepoint-elimination -S < %s | FileCheck %s

declare hotspotcc void @jeandle.safepoint_poll()

; Test non-counted loop (variable step)
; safepoint should NOT be eliminated

define void @non_counted_loop_variable_step(i32 %n, ptr %step.ptr) gc "safepoint-in-non-counted-loop-example" {
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
  ; Variable step - not a counted loop
  %step = load i32, ptr %step.ptr
  %iv.next = add i32 %iv, %step
  br label %loop.header

exit:
  ; Safepoint before ret should NOT be eliminated
  call hotspotcc void @jeandle.safepoint_poll()
  ret void
}

; CHECK-LABEL: @non_counted_loop_variable_step(
; The safepoint should remain in the loop body since this is not a counted loop
; CHECK: call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       exit:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    ret void
