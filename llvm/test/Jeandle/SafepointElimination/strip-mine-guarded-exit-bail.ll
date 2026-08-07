; RUN: opt -passes='safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s

; The exit test is not the header's terminator: it sits in a block reached only
; when a runtime guard %p is true. If %p stays false the counted test never
; runs, so a clamped per-batch inner limit would never be checked -- the
; poll-free inner loop could spin unbounded and hang GC. The transform requires
; the exit test to be the header terminator (so it runs every iteration) and
; declines this shape, leaving the original per-iteration poll in place.

declare hotspotcc void @jeandle.safepoint_poll()

define i64 @g(i64 %n, i1 %p) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %s  = phi i64 [ 0, %entry ], [ %s.next, %latch ]
  br i1 %p, label %check, label %work

check:
  %c = icmp slt i64 %iv, %n
  br i1 %c, label %work, label %exit

work:
  %s.next = add i64 %s, %iv
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %s.next) ]
  br label %latch

latch:
  br label %header

exit:
  %r = phi i64 [ %s, %check ]
  ret i64 %r
}

!java-method-compilation = !{}

; CHECK-LABEL: @g(
; CHECK-NOT:   outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %s.next) ]
