; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal \
; RUN:   -S < %s | FileCheck %s

; C2 treats `i != limit` as a counted loop only for unit strides and a proven
; start/limit order. The strip-mined outer loop uses the equivalent signed
; relational predicate while the inner exit keeps the original equality form.

declare hotspotcc void @jeandle.safepoint_poll()

define void @header_ne_inc(i64 noundef %n) "java-method" {
entry:
  %entry.guard = icmp sle i64 0, %n
  br i1 %entry.guard, label %loop.preheader, label %return

loop.preheader:
  br label %header

header:
  %iv = phi i64 [ 0, %loop.preheader ], [ %iv.next, %latch ]
  %cond = icmp ne i64 %iv, %n
  br i1 %cond, label %body, label %loop.exit

body:
  %iv.next = add nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

loop.exit:
  br label %return

return:
  ret void
}

; CHECK-LABEL: @header_ne_inc(
; CHECK:       latch:
; CHECK:         %cond = icmp ne i64 %iv.next, %outer.inner.limit
; CHECK:         br i1 %cond, label %body, label %body.outer.latch
; CHECK:       body.outer:
; CHECK:         %outer.cond = icmp slt i64 %outer.iv, %n

define void @header_eq_exit_on_true(i64 noundef %n) "java-method" {
entry:
  %entry.guard = icmp sle i64 0, %n
  br i1 %entry.guard, label %loop.preheader, label %return

loop.preheader:
  br label %header

header:
  %iv = phi i64 [ 0, %loop.preheader ], [ %iv.next, %latch ]
  %done = icmp eq i64 %iv, %n
  br i1 %done, label %loop.exit, label %body

body:
  %iv.next = add nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

loop.exit:
  br label %return

return:
  ret void
}

; CHECK-LABEL: @header_eq_exit_on_true(
; CHECK:       latch:
; CHECK:         %done = icmp eq i64 %iv.next, %outer.inner.limit
; CHECK:         br i1 %done, label %body.outer.latch, label %body
; CHECK:       body.outer:
; CHECK:         %outer.cond = icmp slt i64 %outer.iv, %n

define void @latch_ne_inc(i64 noundef %n) "java-method" {
entry:
  %entry.guard = icmp slt i64 0, %n
  br i1 %entry.guard, label %loop.preheader, label %return

loop.preheader:
  br label %header

header:
  %iv = phi i64 [ 0, %loop.preheader ], [ %iv.next, %latch ]
  br label %latch

latch:
  %iv.next = add nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  %cond = icmp ne i64 %iv.next, %n
  br i1 %cond, label %header, label %loop.exit

loop.exit:
  br label %return

return:
  ret void
}

; CHECK-LABEL: @latch_ne_inc(
; CHECK:       latch:
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll
; CHECK:         %cond = icmp ne i64 %iv.next, %outer.inner.limit
; CHECK:         br i1 %cond, label %header, label %header.outer.latch
; CHECK:       header.outer:
; CHECK:         %outer.cond = icmp slt i64 %outer.iv, %n

define void @header_ne_dec(i64 noundef %n) "java-method" {
entry:
  %entry.guard = icmp sge i64 10, %n
  br i1 %entry.guard, label %loop.preheader, label %return

loop.preheader:
  br label %header

header:
  %iv = phi i64 [ 10, %loop.preheader ], [ %iv.next, %latch ]
  %cond = icmp ne i64 %iv, %n
  br i1 %cond, label %body, label %loop.exit

body:
  %iv.next = add nsw i64 %iv, -1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

loop.exit:
  br label %return

return:
  ret void
}

; CHECK-LABEL: @header_ne_dec(
; CHECK:       latch:
; CHECK:         %cond = icmp ne i64 %iv.next, %outer.inner.limit
; CHECK:       body.outer:
; CHECK:         %outer.cond = icmp sgt i64 %outer.iv, %n
; CHECK:         %outer.batch.dist = sub nsw i128
; CHECK:         call i128 @llvm.smin.i128
; CHECK:         %outer.inner.limit = sub nsw i64 %outer.iv, %outer.batch.chunk

define void @header_ne_swapped(i64 noundef %n) "java-method" {
entry:
  %entry.guard = icmp sle i64 0, %n
  br i1 %entry.guard, label %loop.preheader, label %return

loop.preheader:
  br label %header

header:
  %iv = phi i64 [ 0, %loop.preheader ], [ %iv.next, %latch ]
  %cond = icmp ne i64 %n, %iv
  br i1 %cond, label %body, label %loop.exit

body:
  %iv.next = add nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

loop.exit:
  br label %return

return:
  ret void
}

; CHECK-LABEL: @header_ne_swapped(
; CHECK:       latch:
; CHECK:         %cond = icmp ne i64 %outer.inner.limit, %iv.next
; CHECK:       body.outer:
; CHECK:         %outer.cond = icmp slt i64 %outer.iv, %n

define void @latch_ne_dec(i64 noundef %n) "java-method" {
entry:
  %entry.guard = icmp sgt i64 10, %n
  br i1 %entry.guard, label %loop.preheader, label %return

loop.preheader:
  br label %header

header:
  %iv = phi i64 [ 10, %loop.preheader ], [ %iv.next, %latch ]
  br label %latch

latch:
  %iv.next = add nsw i64 %iv, -1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  %cond = icmp ne i64 %iv.next, %n
  br i1 %cond, label %header, label %loop.exit

loop.exit:
  br label %return

return:
  ret void
}

; CHECK-LABEL: @latch_ne_dec(
; CHECK:       latch:
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll
; CHECK:         %cond = icmp ne i64 %iv.next, %outer.inner.limit
; CHECK:         br i1 %cond, label %header, label %header.outer.latch
; CHECK:       header.outer:
; CHECK:         %outer.cond = icmp sgt i64 %outer.iv, %n
; CHECK:         %outer.batch.dist = sub nsw i128
; CHECK:         call i128 @llvm.smin.i128
; CHECK:         %outer.inner.limit = sub nsw i64 %outer.iv, %outer.batch.chunk
!java-method-compilation = !{}
