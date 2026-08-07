; RUN: opt -passes=safepoint-poll-elimination -S < %s | FileCheck %s

; Two polls separated only by lifetime markers. Lifetime markers carry no
; observable side effect (isAdjacencyTransparent), so the polls still collapse
; — the later one survives. On a straight-line (non-loop) block so the
; block-local peephole is exercised.

declare hotspotcc void @jeandle.safepoint_poll()
declare void @llvm.lifetime.start.p0(ptr captures(none))
declare void @llvm.lifetime.end.p0(ptr captures(none))

define void @lifetime_between_polls() "java-method" gc "no-loop" {
entry:
  call hotspotcc void @jeandle.safepoint_poll()
  call void @llvm.lifetime.start.p0(ptr poison)
  call void @llvm.lifetime.end.p0(ptr poison)
  call hotspotcc void @jeandle.safepoint_poll()
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @lifetime_between_polls(
; CHECK:       entry:
; CHECK-NEXT:    call void @llvm.lifetime.start.p0
; CHECK-NEXT:    call void @llvm.lifetime.end.p0
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    ret void
