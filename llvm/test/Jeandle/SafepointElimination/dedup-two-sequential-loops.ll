; RUN: opt -jeandle-loop-strip-mining-iter=0 -passes=safepoint-poll-elimination -S < %s | FileCheck %s

; Two independent loops in one function: each dedups within itself (header
; poll erased, latch poll kept and marked) with no cross-loop bleed. Both are
; non-counted (runtime-flag exits) so this exercises keep-one.

declare hotspotcc void @jeandle.safepoint_poll()

define void @sequential(i1 %keep1, i1 %keep2) "java-method" gc "safepoint-in-loop-example" {
entry:
  br label %first.header

first.header:
  call hotspotcc void @jeandle.safepoint_poll()
  br i1 %keep1, label %first.latch, label %between

first.latch:
  call hotspotcc void @jeandle.safepoint_poll()
  br label %first.header

between:
  br label %second.header

second.header:
  call hotspotcc void @jeandle.safepoint_poll()
  br i1 %keep2, label %second.latch, label %exit

second.latch:
  call hotspotcc void @jeandle.safepoint_poll()
  br label %second.header

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @sequential(
; CHECK:       first.header:
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll
; CHECK:       first.latch:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       second.header:
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll
; CHECK:       second.latch:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
