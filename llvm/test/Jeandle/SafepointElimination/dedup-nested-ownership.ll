; RUN: opt -jeandle-loop-strip-mining-iter=0 -passes=safepoint-poll-elimination -S < %s | FileCheck %s

; Nested loops: the outer loop has two own polls (header + latch) and dedups
; to the latch one; the inner loop's single poll belongs to the inner loop and
; must be neither counted as outer coverage nor deleted by the outer dedup.
; Non-counted loops (runtime-flag exits) so this exercises keep-one.

declare hotspotcc void @jeandle.safepoint_poll()

define void @nested(i1 %inner_keep, i1 %outer_keep) "java-method" gc "safepoint-in-loop-example" {
entry:
  br label %outer.header

outer.header:
  call hotspotcc void @jeandle.safepoint_poll()
  br label %inner.header

inner.header:
  call hotspotcc void @jeandle.safepoint_poll()
  br i1 %inner_keep, label %inner.header, label %outer.latch

outer.latch:
  call hotspotcc void @jeandle.safepoint_poll()
  br i1 %outer_keep, label %outer.header, label %exit

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @nested(
; CHECK:       outer.header:
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll
; CHECK:       inner.header:
; CHECK:         call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       outer.latch:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
