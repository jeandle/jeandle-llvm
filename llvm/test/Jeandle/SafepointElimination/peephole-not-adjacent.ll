; RUN: opt -passes=safepoint-poll-elimination -S < %s | FileCheck %s

; Two polls separated by a real (non-transparent) instruction. A basic block is
; straight-line control, so the later poll is guaranteed to run after the
; earlier one and catches any safepoint request the earlier poll would have —
; the earlier poll is redundant and is removed, regardless of the intervening
; load. Each poll carries its own self-contained deopt state, so dropping the
; earlier one loses nothing. Kept on a straight-line path (no loop) so this
; exercises the block-local collapse alone.

declare hotspotcc void @jeandle.safepoint_poll()

define void @not_adjacent(ptr %a) "java-method" gc "safepoint-in-loop-example" {
entry:
  call hotspotcc void @jeandle.safepoint_poll()
  %v = load i32, ptr %a
  call hotspotcc void @jeandle.safepoint_poll()
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @not_adjacent(
; CHECK:         %v = load i32, ptr %a
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    ret void
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll
