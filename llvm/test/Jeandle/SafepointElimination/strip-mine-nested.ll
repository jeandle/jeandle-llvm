; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal \
; RUN:   -S < %s 2>&1 | FileCheck %s

; A nested loop with a back-edge poll at each level. Strip mining fires only on
; the innermost loop: its poll is relocated to a new strip-mined outer loop and
; the inner latch is marked, while the original outer loop keeps its own poll.
; This exercises reparenting the strip-mined nest under an existing parent loop
; and the coverage verifier across all three resulting loops (it would abort on
; any uncovered loop, so reaching FileCheck proves all three are covered).

declare hotspotcc void @jeandle.safepoint_poll()

define void @nested(i64 %m, i64 %n) "java-method" {
entry:
  br label %outer.h

outer.h:
  %i = phi i64 [ 0, %entry ], [ %i.next, %outer.lat ]
  %ci = icmp slt i64 %i, %m
  br i1 %ci, label %inner.ph, label %exit

inner.ph:
  br label %inner.h

inner.h:
  %j = phi i64 [ 0, %inner.ph ], [ %j.next, %inner.lat ]
  %cj = icmp slt i64 %j, %n
  br i1 %cj, label %inner.body, label %outer.lat

inner.body:
  %j.next = add i64 %j, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %i, i64 %j.next) ]
  br label %inner.lat

inner.lat:
  br label %inner.h

outer.lat:
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %i) ]
  %i.next = add i64 %i, 1
  br label %outer.h

exit:
  ret void
}

!java-method-compilation = !{}

; The innermost loop runs poll-free; its nest is marked via the relocated
; poll's attribute.
; CHECK:       inner.lat:

; The outer loop keeps its own back-edge poll, untouched.
; CHECK:       outer.lat:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %i{{[0-9]*}}) ]

; The inner poll is relocated to the strip-mined outer latch with %j remapped to
; the batch-boundary recurrence and %i (invariant to the inner loop) preserved.
; CHECK:       inner.body.outer.latch:
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}} [ "deopt"(i64 %i{{[0-9]*}}, i64 %outer.iv.next) ]
; CHECK:       attributes #{{[0-9]+}} = { "jeandle.strip-mined-poll" }
