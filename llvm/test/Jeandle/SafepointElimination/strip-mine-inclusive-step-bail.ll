; RUN: opt -passes='safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s

; A strict in-range inclusive limit is not enough for |step| > 1: with
; limit == INT64_MAX - 1, a step-2 IV can overflow after executing the limit
; iteration. Keep the original polling loop unless a stronger no-wrap or limit
; margin proof is available.

declare hotspotcc void @jeandle.safepoint_poll()

define void @incl_step2() "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp sle i64 %iv, 9223372036854775806
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add i64 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

define void @incl_step2_sub_form_bails(i64 %raw) "java-method" {
entry:
  %n = and i64 %raw, 1000000
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp sle i64 %iv, %n
  br i1 %cond, label %body, label %exit

body:
  %iv.next = sub i64 %iv, -2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

define void @uincl_step2_uintmax_minus1_bails() "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp ule i64 %iv, -2
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add i64 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

define void @incl_dec_step2_intmin_plus1_bails() "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ -1, %entry ], [ %iv.next, %latch ]
  %cond = icmp sge i64 %iv, -9223372036854775807
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add i64 %iv, -2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

define void @uincl_dec_step2_one_bails() "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 3, %entry ], [ %iv.next, %latch ]
  %cond = icmp uge i64 %iv, 1
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add i64 %iv, -2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @incl_step2(
; CHECK-NOT:   outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]

; CHECK-LABEL: @incl_step2_sub_form_bails(
; CHECK-NOT:   outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]

; CHECK-LABEL: @uincl_step2_uintmax_minus1_bails(
; CHECK-NOT:   outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]

; CHECK-LABEL: @incl_dec_step2_intmin_plus1_bails(
; CHECK-NOT:   outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]

; CHECK-LABEL: @uincl_dec_step2_one_bails(
; CHECK-NOT:   outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
