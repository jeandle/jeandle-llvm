; RUN: opt -jeandle-loop-strip-mining-iter=4 \
; RUN:   -jeandle-enable-inclusive-loop-versioning \
; RUN:   -jeandle-verify-safepoint-coverage=fatal \
; RUN:   -passes='loop-simplify,lcssa,safepoint-poll-elimination<early>,safepoint-strip-mining<inclusive-loop-versioning>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>,verify' \
; RUN:   -S < %s | FileCheck %s

; A latch-tested source loop executes its first iteration unconditionally. Its
; strip-mined outer loop must therefore test the real limit at the outer latch,
; after the first inner batch. The recurrence no-wrap flags make that direct
; post-tested transformation legal; the unflagged counter at the end remains
; unmined because its first mandatory iteration may wrap.

declare hotspotcc void @jeandle.safepoint_poll()
declare void @use(i32)

define i64 @exclusive_increasing(i64 noundef %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %sum = phi i64 [ 0, %entry ], [ %sum.next, %latch ]
  br label %latch

latch:
  %sum.next = add i64 %sum, %iv
  %iv.next = add nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %sum.next, i64 %iv.next) ]
  %cond = icmp slt i64 %iv.next, %n
  br i1 %cond, label %header, label %exit

exit:
  %result = phi i64 [ %sum.next, %latch ]
  ret i64 %result
}

; CHECK-LABEL: @exclusive_increasing(
; CHECK:       exit:
; CHECK:         %result = phi i64 [ %sum.outer.next, %header.outer.latch ]
; CHECK:       header.outer:
; CHECK:         %sum.outer = phi i64
; CHECK-NOT:     outer.cond
; CHECK:         br label %header.outer.inner.entry
; CHECK:       header.outer.latch:
; CHECK:         %outer.iv.next = phi i64 [ %iv.next, %latch ]
; CHECK:         %sum.outer.next = phi i64 [ %sum.next, %latch ]
; CHECK:         %outer.cond = icmp slt i64 %outer.iv.next, %n
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}} [ "deopt"(i64 %sum.outer.next, i64 %outer.iv.next) ]
; CHECK:         br i1 %outer.cond, label %header.outer, label %exit

define i64 @exclusive_decreasing(i64 noundef %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %sum = phi i64 [ 0, %entry ], [ %sum.next, %latch ]
  br label %latch

latch:
  %sum.next = add i64 %sum, %iv
  %iv.next = add nsw i64 %iv, -1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %sum.next, i64 %iv.next) ]
  %cond = icmp sgt i64 %iv.next, %n
  br i1 %cond, label %header, label %exit

exit:
  %result = phi i64 [ %sum.next, %latch ]
  ret i64 %result
}

; CHECK-LABEL: @exclusive_decreasing(
; CHECK:       exit:
; CHECK:         %result = phi i64 [ %sum.outer.next, %header.outer.latch ]
; CHECK:       header.outer:
; CHECK-NOT:     outer.cond
; CHECK:         br label %header.outer.inner.entry
; CHECK:         %outer.batch.dist = sub nsw i128
; CHECK:         call i128 @llvm.smin.i128
; CHECK:         %outer.inner.limit = sub nsw i64 %outer.iv, %outer.batch.chunk
; CHECK:       header.outer.latch:
; CHECK:         %outer.cond = icmp sgt i64 %outer.iv.next, %n
; CHECK:         call hotspotcc void @jeandle.safepoint_poll()
; CHECK:         br i1 %outer.cond, label %header.outer, label %exit

define i32 @inclusive_increasing(i32 noundef %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %latch ]
  br label %latch

latch:
  %iv.next = add nsw i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %cond = icmp sle i32 %iv.next, %n
  br i1 %cond, label %header, label %exit

exit:
  %result = phi i32 [ %iv.next, %latch ]
  ret i32 %result
}

; CHECK-LABEL: @inclusive_increasing(
; CHECK-NOT:     inclusive.version.guard
; CHECK:       exit:
; CHECK:         %result = phi i32 [ %outer.iv.next, %header.outer.latch ]
; CHECK:       header.outer:
; CHECK-NOT:     outer.cond
; CHECK:         br label %header.outer.inner.entry
; CHECK:         %outer.batch.dist = sub nsw i64
; CHECK:         call i64 @llvm.smin.i64
; CHECK:         %outer.inner.limit = add nsw i32 %outer.iv, %outer.batch.chunk
; CHECK:       header.outer.latch:
; CHECK:         %outer.cond = icmp sle i32 %outer.iv.next, %n
; CHECK:         call hotspotcc void @jeandle.safepoint_poll()
; CHECK:         br i1 %outer.cond, label %header.outer, label %exit

define i32 @inclusive_decreasing(i32 noundef %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %latch ]
  br label %latch

latch:
  %iv.next = add nsw i32 %iv, -1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %cond = icmp sge i32 %iv.next, %n
  br i1 %cond, label %header, label %exit

exit:
  ret i32 %iv.next
}

; CHECK-LABEL: @inclusive_decreasing(
; CHECK-NOT:     inclusive.version.guard
; CHECK:       exit:
; CHECK:         %iv.next.lcssa = phi i32 [ %outer.iv.next, %header.outer.latch ]
; CHECK:       header.outer:
; CHECK-NOT:     outer.cond
; CHECK:         br label %header.outer.inner.entry
; CHECK:         %outer.batch.dist = sub nsw i64
; CHECK:         call i64 @llvm.smin.i64
; CHECK:         %outer.inner.limit = sub nsw i32 %outer.iv, %outer.batch.chunk
; CHECK:       header.outer.latch:
; CHECK:         %outer.cond = icmp sge i32 %outer.iv.next, %n
; CHECK:         call hotspotcc void @jeandle.safepoint_poll()
; CHECK:         br i1 %outer.cond, label %header.outer, label %exit

define i32 @exclusive_unsigned_increasing(i32 noundef %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %latch ]
  br label %latch

latch:
  %iv.next = add nuw i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %cond = icmp ult i32 %iv.next, %n
  br i1 %cond, label %header, label %exit

exit:
  ret i32 %iv.next
}

; CHECK-LABEL: @exclusive_unsigned_increasing(
; CHECK:       header.outer:
; CHECK-NOT:     outer.cond
; CHECK:         br label %header.outer.inner.entry
; CHECK:         call i32 @llvm.uadd.sat.i32(i32 %outer.iv, i32 4)
; CHECK:       header.outer.latch:
; CHECK:         %outer.cond = icmp ult i32 %outer.iv.next, %n
; CHECK:         call hotspotcc void @jeandle.safepoint_poll()
; CHECK:         br i1 %outer.cond, label %header.outer, label %exit

define i32 @current_iv_with_lag(i32 noundef %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %latch ]
  %last = phi i32 [ -1, %entry ], [ %iv, %latch ]
  br label %latch

latch:
  call void @use(i32 %last)
  %iv.next = add nsw i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %cond = icmp slt i32 %iv.next, %n
  br i1 %cond, label %header, label %exit

exit:
  %current = phi i32 [ %iv, %latch ]
  ret i32 %current
}

; CHECK-LABEL: @current_iv_with_lag(
; CHECK:       exit:
; CHECK:         %current = phi i32 [ %last.outer.next, %header.outer.latch ]
; CHECK:       header.outer:
; CHECK:         %last.outer = phi i32
; CHECK-NOT:     outer.cond
; CHECK:         br label %header.outer.inner.entry
; CHECK:       header.outer.latch:
; CHECK:         %last.outer.next = phi i32 [ %iv, %latch ]
; CHECK:         %outer.cond = icmp slt i32 %outer.iv.next, %n
; CHECK:         call hotspotcc void @jeandle.safepoint_poll()
; CHECK:         br i1 %outer.cond, label %header.outer, label %exit

define void @exclusive_without_nowrap(i64 noundef %start,
                                      i64 noundef %limit) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ %start, %entry ], [ %iv.next, %latch ]
  br label %latch

latch:
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  %cond = icmp slt i64 %iv.next, %limit
  br i1 %cond, label %header, label %exit

exit:
  ret void
}

; CHECK-LABEL: @exclusive_without_nowrap(
; CHECK-NOT:   .outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
; CHECK-NOT:   jeandle.strip-mined-poll

!java-method-compilation = !{}

; CHECK: attributes #{{[0-9]+}} = { "jeandle.strip-mined-poll" }
