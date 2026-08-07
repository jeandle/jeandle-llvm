; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' \
; RUN:   -jeandle-loop-strip-mining-iter=10 -S < %s | FileCheck %s
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal \
; RUN:   -jeandle-loop-strip-mining-iter=10 -disable-output < %s

; Exclusive non-unit loops may use a dominating entry guard to prove the real
; limit is far enough from the type edge. Transform and verifier must both
; replay that same real-limit proof.

declare hotspotcc void @jeandle.safepoint_poll()

define void @exclusive_step2_entry_guard(i64 noundef %n) "java-method" {
entry:
  %guard = icmp slt i64 %n, 1000
  br i1 %guard, label %preheader, label %return

preheader:
  br label %header

header:
  %iv = phi i64 [ 0, %preheader ], [ %iv.next, %latch ]
  %cond = icmp slt i64 %iv, %n
  br i1 %cond, label %body, label %loop.exit

body:
  %iv.next = add i64 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

loop.exit:
  br label %return

return:
  ret void
}

; CHECK-LABEL: @exclusive_step2_entry_guard(
; CHECK:         .outer
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}}

define void @exclusive_step2_wrong_edge_guard_bails(i64 noundef %n) "java-method" {
entry:
  %guard = icmp slt i64 %n, 1000
  br i1 %guard, label %return, label %preheader

preheader:
  br label %header

header:
  %iv = phi i64 [ 0, %preheader ], [ %iv.next, %latch ]
  %cond = icmp slt i64 %iv, %n
  br i1 %cond, label %body, label %loop.exit

body:
  %iv.next = add i64 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

loop.exit:
  br label %return

return:
  ret void
}

; CHECK-LABEL: @exclusive_step2_wrong_edge_guard_bails(
; CHECK-NOT:     .outer
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
; CHECK-NOT:     jeandle.strip-mined-poll

; A unit-step exclusive loop does not need a range guard for no-wrap, but the
; duplicated real limit still needs one stable value across the outer
; condition, cap and inner exit.
define void @exclusive_unit_unstable_limit(i64 %n, i1 %choose) "java-method" {
entry:
  %limit = select i1 %choose, i64 %n, i64 undef
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp slt i64 %iv, %limit
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

; CHECK-LABEL: @exclusive_unit_unstable_limit(
; CHECK:         %exclusive.limit.fr = freeze i64 %limit
; CHECK:         .outer
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}}

!java-method-compilation = !{}

; CHECK:       attributes #{{[0-9]+}} = { "jeandle.strip-mined-poll" }
