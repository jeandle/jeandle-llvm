; RUN: opt -passes=safepoint-elimination -S < %s | FileCheck %s

; A counted loop where the front-end has placed two distinct safepoint polls:
;   * one on the back-edge path (loop.body → loop.latch)
;   * one on a side-exit slow path that leads to an uncommon_trap.
; Only the back-edge poll is removed; the side-exit poll carries deopt JVM
; state and must be preserved.

declare hotspotcc void @jeandle.safepoint_poll()
declare void @uncommon_trap(i32) noreturn

define void @side_exit_preserved(i32 %n, i1 %slow) gc "side-exit" {
entry:
  %cmp = icmp sgt i32 %n, 0
  br i1 %cmp, label %loop.header, label %exit

loop.header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop.latch ]
  %exit.cond = icmp slt i32 %iv, %n
  br i1 %exit.cond, label %loop.body, label %exit

loop.body:
  br i1 %slow, label %slow_path, label %fast_path

fast_path:
  call hotspotcc void @jeandle.safepoint_poll()
  br label %loop.latch

slow_path:
  call hotspotcc void @jeandle.safepoint_poll()
  call void @uncommon_trap(i32 -1)
  unreachable

loop.latch:
  %iv.next = add nsw i32 %iv, 1
  br label %loop.header

exit:
  call hotspotcc void @jeandle.safepoint_poll()
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @side_exit_preserved(
;
; Fast path's poll is on the back-edge — eliminated:
; CHECK:       fast_path:
; CHECK-NEXT:    br label %loop.latch
;
; Slow path's poll precedes uncommon_trap — preserved:
; CHECK:       slow_path:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    call void @uncommon_trap
;
; Exit-block poll is preserved:
; CHECK:       {{^exit:}}
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    ret void
