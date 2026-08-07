; RUN: opt -passes=safepoint-poll-elimination -S < %s | FileCheck %s

; Module is NOT marked as a compiled Java method (no !java-method-compilation
; named metadata). The pass must bail before touching anything, so the two
; adjacent polls it would otherwise collapse are both preserved.

declare hotspotcc void @jeandle.safepoint_poll()

define void @no_metadata() gc "no-jmc" {
entry:
  call hotspotcc void @jeandle.safepoint_poll()
  call hotspotcc void @jeandle.safepoint_poll()
  ret void
}

; CHECK-LABEL: @no_metadata(
; CHECK:       entry:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    ret void
