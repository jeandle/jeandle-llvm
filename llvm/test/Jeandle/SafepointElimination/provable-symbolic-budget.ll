; RUN: opt -passes='safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' \
; RUN:   -jeandle-loop-strip-mining-iter=1000 -S < %s | FileCheck %s

; A symbolic bound established by llvm.assume is as useful as a constant
; bound. The loop is at most 1000 trips, so its poll is deleted rather than
; retained or relocated.

declare hotspotcc void @jeandle.safepoint_poll()

define void @symbolic_within_budget(i32 %n) "java-method" {
entry:
  %positive = icmp ne i32 %n, 0
  br i1 %positive, label %bounds, label %exit

bounds:
  %max.backedge = add i32 %n, -1
  %small = icmp ult i32 %max.backedge, 1000
  br i1 %small, label %preheader, label %exit

preheader:
  br label %loop

loop:
  %iv = phi i32 [ 0, %preheader ], [ %iv.next, %loop ]
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv) ]
  %iv.next = add nuw i32 %iv, 1
  %continue = icmp ult i32 %iv.next, %n
  br i1 %continue, label %loop, label %exit

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @symbolic_within_budget(
; CHECK-NOT:   call hotspotcc void @jeandle.safepoint_poll
; CHECK:       exit:
