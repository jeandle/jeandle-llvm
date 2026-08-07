; RUN: opt -passes='safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-loop-strip-mining-iter=1 -S < %s | FileCheck %s --check-prefix=ONE
; RUN: opt -passes='safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-loop-strip-mining-iter=1000 -S < %s | FileCheck %s --check-prefix=BUDGET
; RUN: opt -passes='safepoint-poll-elimination<early>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-loop-strip-mining-iter=0 -S < %s | FileCheck %s --check-prefix=INT

declare hotspotcc void @jeandle.safepoint_poll()

; With an exclusive budget of one, zero taken backedges are within budget.
define void @zero_backedges_with_budget_one(ptr %sink) "java-method" {
entry:
  br label %loop

loop:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop ]
  store volatile i32 %iv, ptr %sink, align 4
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv) ]
  %iv.next = add nuw nsw i32 %iv, 1
  %continue = icmp ult i32 %iv.next, 1
  br i1 %continue, label %loop, label %exit

exit:
  ret void
}

; ONE-LABEL: @zero_backedges_with_budget_one(
; ONE-NOT:   call hotspotcc void @jeandle.safepoint_poll

; One taken backedge is exactly the exclusive limit and is not within a
; budget of one.
define void @one_backedge_with_budget_one(ptr %sink) "java-method" {
entry:
  br label %loop

loop:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop ]
  store volatile i32 %iv, ptr %sink, align 4
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv) ]
  %iv.next = add nuw nsw i32 %iv, 1
  %continue = icmp ult i32 %iv.next, 2
  br i1 %continue, label %loop, label %exit

exit:
  ret void
}

; ONE-LABEL: @one_backedge_with_budget_one(
; ONE:       call hotspotcc void @jeandle.safepoint_poll()

; Every i8 backedge count is less than 1000. This exercises the narrow-type
; fast path without constructing a wrapped i8 representation of the limit.
define void @narrow_i8_count(ptr %sink) "java-method" {
entry:
  br label %loop

loop:
  %iv = phi i8 [ 0, %entry ], [ %iv.next, %loop ]
  store volatile i8 %iv, ptr %sink, align 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i8 %iv) ]
  %iv.next = add nuw i8 %iv, 1
  %continue = icmp ult i8 %iv.next, -1
  br i1 %continue, label %loop, label %exit

exit:
  ret void
}

; BUDGET-LABEL: @narrow_i8_count(
; BUDGET-NOT:   call hotspotcc void @jeandle.safepoint_poll

; A wide SCEV count immediately below the exclusive budget is accepted.
define void @wide_i128_below_budget(ptr %sink) "java-method" {
entry:
  br label %loop

loop:
  %iv = phi i128 [ 0, %entry ], [ %iv.next, %loop ]
  store volatile i128 %iv, ptr %sink, align 16
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i128 %iv) ]
  %iv.next = add nuw nsw i128 %iv, 1
  %continue = icmp ult i128 %iv.next, 1000
  br i1 %continue, label %loop, label %exit

exit:
  ret void
}

; BUDGET-LABEL: @wide_i128_below_budget(
; BUDGET-NOT:   call hotspotcc void @jeandle.safepoint_poll

; A wide SCEV count equal to the exclusive budget is rejected.
define void @wide_i128_at_budget(ptr %sink) "java-method" {
entry:
  br label %loop

loop:
  %iv = phi i128 [ 0, %entry ], [ %iv.next, %loop ]
  store volatile i128 %iv, ptr %sink, align 16
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i128 %iv) ]
  %iv.next = add nuw nsw i128 %iv, 1
  %continue = icmp ult i128 %iv.next, 1001
  br i1 %continue, label %loop, label %exit

exit:
  ret void
}

; BUDGET-LABEL: @wide_i128_at_budget(
; BUDGET:       call hotspotcc void @jeandle.safepoint_poll()

; An entry guard that proves only max BTC <= 1000 cannot satisfy the strict
; max BTC < 1000 budget check. This exercises the contextual and loop-entry
; predicate paths with equality still possible.
define void @symbolic_guard_may_equal_budget(i32 %n, ptr %sink) "java-method" {
entry:
  %nonzero = icmp ne i32 %n, 0
  br i1 %nonzero, label %bounds, label %exit

bounds:
  %max.backedge = add i32 %n, -1
  %within.inclusive = icmp ule i32 %max.backedge, 1000
  br i1 %within.inclusive, label %preheader, label %exit

preheader:
  br label %loop

loop:
  %iv = phi i32 [ 0, %preheader ], [ %iv.next, %loop ]
  store volatile i32 %iv, ptr %sink, align 4
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv) ]
  %iv.next = add nuw i32 %iv, 1
  %continue = icmp ult i32 %iv.next, %n
  br i1 %continue, label %loop, label %exit

exit:
  ret void
}

; BUDGET-LABEL: @symbolic_guard_may_equal_budget(
; BUDGET:       call hotspotcc void @jeandle.safepoint_poll()

; In a pre-test loop, the latch-to-header edge is taken once per body
; iteration. INT_MAX-1 backedges satisfy the strict INT_MAX threshold.
define void @pretest_i32_below_int_max(ptr %sink) "java-method" {
entry:
  br label %header

header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %latch ]
  %continue = icmp slt i32 %iv, 2147483646
  br i1 %continue, label %latch, label %exit

latch:
  store volatile i32 %iv, ptr %sink, align 4
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv) ]
  %iv.next = add nuw nsw i32 %iv, 1
  br label %header

exit:
  ret void
}

; INT-LABEL: @pretest_i32_below_int_max(
; INT-NOT:   call hotspotcc void @jeandle.safepoint_poll

; INT_MAX backedges are equal to the exclusive threshold and retain coverage.
define void @pretest_i32_at_int_max(ptr %sink) "java-method" {
entry:
  br label %header

header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %latch ]
  %continue = icmp slt i32 %iv, 2147483647
  br i1 %continue, label %latch, label %exit

latch:
  store volatile i32 %iv, ptr %sink, align 4
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv) ]
  %iv.next = add nuw nsw i32 %iv, 1
  br label %header

exit:
  ret void
}

; INT-LABEL: @pretest_i32_at_int_max(
; INT:       call hotspotcc void @jeandle.safepoint_poll()

; IsIntCountedEquivalent remains a numerical threshold rather than an IV-type
; recognizer: an i64 count below INT_MAX is accepted.
define void @pretest_i64_below_int_max(ptr %sink) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %continue = icmp slt i64 %iv, 2147483646
  br i1 %continue, label %latch, label %exit

latch:
  store volatile i64 %iv, ptr %sink, align 8
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv) ]
  %iv.next = add nuw nsw i64 %iv, 1
  br label %header

exit:
  ret void
}

; INT-LABEL: @pretest_i64_below_int_max(
; INT-NOT:   call hotspotcc void @jeandle.safepoint_poll

; The same i64 shape at INT_MAX is rejected without truncating the limit.
define void @pretest_i64_at_int_max(ptr %sink) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %continue = icmp slt i64 %iv, 2147483647
  br i1 %continue, label %latch, label %exit

latch:
  store volatile i64 %iv, ptr %sink, align 8
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv) ]
  %iv.next = add nuw nsw i64 %iv, 1
  br label %header

exit:
  ret void
}

; INT-LABEL: @pretest_i64_at_int_max(
; INT:       call hotspotcc void @jeandle.safepoint_poll()

!java-method-compilation = !{}
