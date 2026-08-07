; RUN: opt -passes=safepoint-poll-elimination -S < %s | FileCheck %s

; Two polls separated only by an `llvm.pseudoprobe` call. A pseudo probe has no
; observable side effect (isAdjacencyTransparent), so the polls collapse and the
; probe stays (the later poll survives). On a straight-line (non-loop) block so
; the block-local peephole is exercised.

declare hotspotcc void @jeandle.safepoint_poll()
declare void @llvm.pseudoprobe(i64, i64, i32, i64)

define void @pseudoprobe_between_polls() "java-method" gc "no-loop" {
entry:
  call hotspotcc void @jeandle.safepoint_poll()
  call void @llvm.pseudoprobe(i64 0, i64 1, i32 0, i64 -1)
  call hotspotcc void @jeandle.safepoint_poll()
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @pseudoprobe_between_polls(
; CHECK:       entry:
; CHECK-NEXT:    call void @llvm.pseudoprobe(i64 0, i64 1, i32 0, i64 -1)
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    ret void
