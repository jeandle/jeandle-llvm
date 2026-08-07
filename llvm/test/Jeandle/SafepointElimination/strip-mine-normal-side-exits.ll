; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal \
; RUN:   -disable-output < %s

; A counted loop with a normal side exit: `if (iv == target) return` leaves the
; loop nest instead of continuing around the back-edge. Strip mining only needs
; the primary trip-counter exit to cut every continuing path into chunks; normal
; side exits ride along untouched, with deopt exits just one special case.

declare hotspotcc void @jeandle.safepoint_poll()

define i64 @search(i64 %n, i64 %target) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %s  = phi i64 [ 0, %entry ], [ %s.next, %latch ]
  %cond = icmp slt i64 %iv, %n
  br i1 %cond, label %body, label %exit

body:
  %found = icmp eq i64 %iv, %target
  br i1 %found, label %early.ret, label %cont

cont:
  %s.next = add i64 %s, %iv
  %iv.next = add nuw nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %s.next, i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  %sl = phi i64 [ %s, %header ]
  ret i64 %sl

early.ret:
  %se = phi i64 [ %s, %body ]
  ret i64 %se
}

!java-method-compilation = !{}

; CHECK-LABEL: @search(
; CHECK:       body:
; CHECK:         %found = icmp eq i64 %iv2, %target
; CHECK:         br i1 %found, label %early.ret, label %cont
; CHECK:       cont:
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll
; CHECK:         br label %latch
; CHECK:       latch:
; CHECK:         %cond = icmp slt i64 %iv.next, %outer.inner.limit
; CHECK:         br i1 %cond, label %body, label %body.outer.latch
; CHECK:       exit:
; CHECK:         %sl = phi i64
; CHECK:       early.ret:
; CHECK:         %se = phi i64 [ %s3, %body ]
; CHECK:       body.outer.latch:
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}} [ "deopt"(i64 %s3.outer.next, i64 %outer.iv.next) ]

define i64 @search_two_side_exits(i64 %n, i64 %target1, i64 %target2) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %s  = phi i64 [ 0, %entry ], [ %s.next, %latch ]
  %cond = icmp slt i64 %iv, %n
  br i1 %cond, label %body, label %exit

body:
  %found1 = icmp eq i64 %iv, %target1
  br i1 %found1, label %first.ret, label %check.second

check.second:
  %found2 = icmp eq i64 %iv, %target2
  br i1 %found2, label %second.ret, label %cont

cont:
  %s.next = add i64 %s, %iv
  %iv.next = add nuw nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %s.next, i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  %sl = phi i64 [ %s, %header ]
  ret i64 %sl

first.ret:
  %sf = phi i64 [ %s, %body ]
  ret i64 %sf

second.ret:
  %ss = phi i64 [ %s, %check.second ]
  ret i64 %ss
}

; CHECK-LABEL: @search_two_side_exits(
; CHECK:       body:
; CHECK:         br i1 %found1, label %first.ret, label %check.second
; CHECK:       check.second:
; CHECK:         br i1 %found2, label %second.ret, label %cont
; CHECK:       cont:
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll
; CHECK:         br label %latch
; CHECK:       latch:
; CHECK:         br i1 %cond, label %body, label %body.outer.latch
; CHECK:       first.ret:
; CHECK:         %sf = phi i64 [ %s3, %body ]
; CHECK:       second.ret:
; CHECK:         %ss = phi i64 [ %s3, %check.second ]
; CHECK:       body.outer.latch:
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}} [ "deopt"(i64 %s3.outer.next, i64 %outer.iv.next) ]
