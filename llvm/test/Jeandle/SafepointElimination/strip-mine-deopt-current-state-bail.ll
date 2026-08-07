; RUN: opt -passes='safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' \
; RUN:   -S < %s | FileCheck %s

declare hotspotcc void @jeandle.safepoint_poll()

; A raw header phi is current-iteration state, not the batch-boundary next
; state. Availability at the outer latch is not a semantic relocation proof.
define void @current_iv_bails(i64 %n) "java-method" {
entry:
  br label %header
header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp slt i64 %iv, %n
  br i1 %cond, label %body, label %exit
body:
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv) ]
  br label %latch
latch:
  br label %header
exit:
  ret void
}

; CHECK-LABEL: @current_iv_bails(
; CHECK-NOT:   .outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv) ]

; In a swap recurrence, %a is both a raw header phi and %b's latch incoming
; value. Header-phi rejection must take precedence over latch-value matching.
define void @header_phi_that_is_another_next_bails(i64 %n) "java-method" {
entry:
  br label %header
header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %a = phi i64 [ 1, %entry ], [ %b, %latch ]
  %b = phi i64 [ 2, %entry ], [ %a, %latch ]
  %cond = icmp slt i64 %iv, %n
  br i1 %cond, label %body, label %exit
body:
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next, i64 %a) ]
  br label %latch
latch:
  br label %header
exit:
  ret void
}

; CHECK-LABEL: @header_phi_that_is_another_next_bails(
; CHECK-NOT:   .outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next, i64 %a) ]

!java-method-compilation = !{}
