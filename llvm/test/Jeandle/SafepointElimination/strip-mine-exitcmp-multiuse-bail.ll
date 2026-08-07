; RUN: opt -passes='safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s

; The exit compare %cond has a second use (a select in the body) besides the
; exit branch. Strip mining rewrites the compare's limit operand in place to the
; clamped per-batch limit; if %cond fed anything else, that user would silently
; start reading the clamped limit instead of the real one -- a miscompile. The
; transform requires the exit compare to be used only by the exit branch and
; declines otherwise, leaving the loop's poll in place.

declare hotspotcc void @jeandle.safepoint_poll()

define i64 @h(i64 %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %s  = phi i64 [ 0, %entry ], [ %s.next, %latch ]
  %cond = icmp slt i64 %iv, %n
  br i1 %cond, label %body, label %exit

body:
  %pick = select i1 %cond, i64 %iv, i64 0
  %s.next = add i64 %s, %pick
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %s.next) ]
  br label %latch

latch:
  br label %header

exit:
  %r = phi i64 [ %s, %header ]
  ret i64 %r
}

!java-method-compilation = !{}

; The compare keeps its original limit operand (%n, not a clamped limit) and no
; outer loop is created.
; CHECK-LABEL: @h(
; CHECK-NOT:   outer
; CHECK:       %cond = icmp slt i64 %iv, %n
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %s.next) ]
