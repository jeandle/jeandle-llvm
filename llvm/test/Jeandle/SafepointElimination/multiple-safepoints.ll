; RUN: opt -passes=safepoint-elimination -S < %s | FileCheck %s

declare hotspotcc void @jeandle.safepoint_poll()

; Test counted loop with multiple safepoints
;
define void @counted_loop_multiple_safepoints(i32 %n) gc "multiple-safepoints-example" {
entry:
  %cmp = icmp sgt i32 %n, 0
  br i1 %cmp, label %loop.header, label %exit

loop.header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop.latch ]
  %exit.cond = icmp slt i32 %iv, %n
  br i1 %exit.cond, label %loop.body, label %exit

loop.body:
  ; First safepoint - should be eliminated
  call hotspotcc void @jeandle.safepoint_poll()
  
  ; Some work
  %val1 = load i32, ptr null
  
  ; Second safepoint - should be eliminated
  call hotspotcc void @jeandle.safepoint_poll()
  
  ; More work
  %val2 = load i32, ptr null
  
  ; Third safepoint - should be eliminated
  call hotspotcc void @jeandle.safepoint_poll()
  
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

; CHECK-LABEL: @counted_loop_multiple_safepoints(
; CHECK-NOT: call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       {{^exit:}}
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    ret void
