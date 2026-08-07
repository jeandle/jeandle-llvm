; RUN: opt -passes=safepoint-poll-elimination -S < %s | FileCheck %s

; Adjacent polls outside any loop (the shape inlining produces: a callee's
; return poll landing next to the caller's poll) also collapse — the pass is
; not loop-scoped.

declare hotspotcc void @jeandle.safepoint_poll()

define void @straight_line() "java-method" gc "no-loop" {
entry:
  call hotspotcc void @jeandle.safepoint_poll()
  call hotspotcc void @jeandle.safepoint_poll()
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @straight_line(
; CHECK:       entry:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    ret void
