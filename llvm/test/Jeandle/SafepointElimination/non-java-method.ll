; RUN: opt -passes=safepoint-elimination -S < %s | FileCheck %s

; Module is NOT marked as compiled-java-method (no !java-method-compilation
; named metadata). The pass must leave the IR untouched.

declare hotspotcc void @jeandle.safepoint_poll()

define void @no_metadata(i32 %n) gc "no-jmc" {
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
  %iv.next = add nsw i32 %iv, 1
  br label %loop.header

exit:
  ret void
}

; CHECK-LABEL: @no_metadata(
; CHECK:       loop.body:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
