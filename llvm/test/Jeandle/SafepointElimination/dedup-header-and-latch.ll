; RUN: opt -jeandle-loop-strip-mining-iter=0 -passes=safepoint-poll-elimination -S < %s | FileCheck %s

; Two polls both dominate the latch (header and latch). Keep-one keeps the
; latch-closest — the one in the latch itself — and erases the header's. The
; loop exits on a runtime flag rather than an induction variable, so this is a
; non-counted loop exercising keep-one (counted loops are handled separately).

declare hotspotcc void @jeandle.safepoint_poll()

define void @header_and_latch(i1 %keep_going) "java-method" gc "safepoint-in-loop-example" {
entry:
  br label %loop.header

loop.header:
  call hotspotcc void @jeandle.safepoint_poll()
  br i1 %keep_going, label %loop.latch, label %exit

loop.latch:
  call hotspotcc void @jeandle.safepoint_poll()
  br label %loop.header

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @header_and_latch(
; CHECK:       loop.header:
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll
; CHECK:       loop.latch:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
