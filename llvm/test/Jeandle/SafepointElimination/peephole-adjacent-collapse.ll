; RUN: opt -passes=safepoint-poll-elimination -S < %s | FileCheck %s

; Two `jeandle.safepoint_poll` calls sit back to back on the same straight-line
; (non-loop) block. They collapse to one, keeping the later. The pass is not
; loop-scoped (collapse runs on blocks outside any loop; loop-block polls are
; deferred to loop poll deletion).

declare hotspotcc void @jeandle.safepoint_poll()

define void @adjacent_polls() "java-method" gc "no-loop" {
entry:
  call hotspotcc void @jeandle.safepoint_poll()
  call hotspotcc void @jeandle.safepoint_poll()
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @adjacent_polls(
; CHECK:       entry:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    ret void
