; RUN: opt -passes='safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s

; A latch compare against the current IV is a supported affine recurrence. Its
; batch clamp is one step nearer than the equivalent next-IV compare, while
; the relocated poll resumes from iv.next. A non-canonical subtraction step
; remains unsupported and must keep its original poll.

declare hotspotcc void @jeandle.safepoint_poll()

define void @latch_old_iv(i64 %n) "java-method" {
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
  %cond = icmp slt i64 %iv, %n
  br i1 %cond, label %header, label %loop.exit

loop.exit:
  br label %return

return:
  ret void
}

; CHECK-LABEL: @latch_old_iv(
; CHECK:       header.outer:
; CHECK:       %outer.batch.chunk.wide = call i128 @llvm.smin.i128(i128 %outer.batch.rem, i128 999)
; CHECK:       %outer.inner.limit = add nsw i64 %outer.iv, %outer.batch.chunk
; CHECK:       header.outer.latch:
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() #[[POLL:[0-9]+]] [ "deopt"(i64 %outer.iv.next) ]

define void @latch_next_sub_form(i64 %n) "java-method" {
entry:
  %entry.guard = icmp slt i64 0, %n
  br i1 %entry.guard, label %loop.preheader, label %return

loop.preheader:
  br label %header

header:
  %iv = phi i64 [ 0, %loop.preheader ], [ %iv.next, %latch ]
  br label %latch

latch:
  %iv.next = sub nuw nsw i64 %iv, -1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  %cond = icmp slt i64 %iv.next, %n
  br i1 %cond, label %header, label %loop.exit

loop.exit:
  br label %return

return:
  ret void
}

; CHECK-LABEL: @latch_next_sub_form(
; CHECK-NOT:   .outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
; CHECK:       attributes #[[POLL]] = { "jeandle.strip-mined-poll" }

!java-method-compilation = !{}
