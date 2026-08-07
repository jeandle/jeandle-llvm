; RUN: opt -passes='safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s

; The loop value %iv is used directly in the exit (`ret %iv`) rather than
; through an LCSSA phi. Strip mining would move the exit edge to the outer
; header, where %iv no longer dominates the use. The pass requires LCSSA form
; and bails here rather than producing malformed IR.

declare hotspotcc void @jeandle.safepoint_poll()

define i64 @loop(i64 %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp slt i64 %iv, %n
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret i64 %iv
}

!java-method-compilation = !{}

; CHECK-LABEL: @loop(
; CHECK-NOT:   outer
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
