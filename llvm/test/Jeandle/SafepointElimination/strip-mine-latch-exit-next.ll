; RUN: opt -passes='safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal \
; RUN:   -S < %s | FileCheck %s

; C2's counted-loop shape is post-increment: the latch compares the next IV.
; Strip mining accepts that shape only when a loop-entry guard proves the body
; is not an unguarded do-while first iteration.

declare hotspotcc void @jeandle.safepoint_poll()

define i64 @latch_exit_sum(i64 noundef %n) "java-method" {
entry:
  %entry.guard = icmp slt i64 0, %n
  br i1 %entry.guard, label %loop.preheader, label %return

loop.preheader:
  br label %header

header:
  %iv = phi i64 [ 0, %loop.preheader ], [ %iv.next, %latch ]
  %sum = phi i64 [ 0, %loop.preheader ], [ %sum.next, %latch ]
  br label %latch

latch:
  %sum.next = add i64 %sum, %iv
  %iv.next = add nuw nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next, i64 %sum.next) ]
  %cond = icmp slt i64 %iv.next, %n
  br i1 %cond, label %header, label %loop.exit

loop.exit:
  %sum.lcssa = phi i64 [ %sum.next, %latch ]
  br label %return

return:
  %result = phi i64 [ 0, %entry ], [ %sum.lcssa, %loop.exit ]
  ret i64 %result
}

; CHECK-LABEL: @latch_exit_sum(
; CHECK:       latch:
; CHECK:         %sum.next = add i64 %sum, %iv
; CHECK:         %iv.next = add nuw nsw i64 %iv, 1
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll
; CHECK:         %cond = icmp slt i64 %iv.next, %outer.inner.limit
; CHECK:         br i1 %cond, label %header, label %header.outer.latch

; CHECK:       loop.exit:
; CHECK:         %sum.lcssa = phi i64 [ %sum.outer, %header.outer ]

; CHECK:       header.outer:
; CHECK:         %sum.outer = phi i64 [ 0, %header.outer.ph ], [ %sum.outer.next, %header.outer.latch ]
; CHECK:         %outer.cond = icmp slt i64 %outer.iv, %n

; CHECK:       header.outer.latch:
; CHECK:         %outer.iv.next = phi i64 [ %iv.next, %latch ]
; CHECK:         %sum.outer.next = phi i64 [ %sum.next, %latch ]
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}} [ "deopt"(i64 %outer.iv.next, i64 %sum.outer.next) ]

define void @latch_exit_swapped(i64 noundef %n) "java-method" {
entry:
  %entry.guard = icmp slt i64 0, %n
  br i1 %entry.guard, label %loop.preheader, label %return

loop.preheader:
  br label %header

header:
  %iv = phi i64 [ 0, %loop.preheader ], [ %iv.next, %latch ]
  br label %latch

latch:
  %iv.next = add nuw nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  %cond = icmp sgt i64 %n, %iv.next
  br i1 %cond, label %header, label %loop.exit

loop.exit:
  br label %return

return:
  ret void
}

; CHECK-LABEL: @latch_exit_swapped(
; CHECK:       latch:
; CHECK:         %cond = icmp sgt i64 %outer.inner.limit, %iv.next
; CHECK:         br i1 %cond, label %header, label %header.outer.latch
; CHECK:       header.outer:
; CHECK:         %outer.cond = icmp slt i64 %outer.iv, %n
; CHECK:       header.outer.latch:
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}} [ "deopt"(i64 %outer.iv.next) ]

define void @latch_exit_exit_on_true(i64 noundef %n) "java-method" {
entry:
  %entry.guard = icmp slt i64 0, %n
  br i1 %entry.guard, label %loop.preheader, label %return

loop.preheader:
  br label %header

header:
  %iv = phi i64 [ 0, %loop.preheader ], [ %iv.next, %latch ]
  br label %latch

latch:
  %iv.next = add nuw nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  %done = icmp sge i64 %iv.next, %n
  br i1 %done, label %loop.exit, label %header

loop.exit:
  br label %return

return:
  ret void
}

; CHECK-LABEL: @latch_exit_exit_on_true(
; CHECK:       latch:
; CHECK:         %done = icmp sge i64 %iv.next, %outer.inner.limit
; CHECK:         br i1 %done, label %header.outer.latch, label %header
; CHECK:       header.outer:
; CHECK:         %outer.cond = icmp slt i64 %outer.iv, %n
; CHECK:       header.outer.latch:
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}} [ "deopt"(i64 %outer.iv.next) ]

!java-method-compilation = !{}
