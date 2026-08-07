; RUN: opt -passes='safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -S < %s | FileCheck %s

; When several loop-owned polls dominate the latch, relocate the one closest to
; the latch. The choice follows the dominator chain and does not depend on
; Loop::blocks() traversal order.

declare hotspotcc void @jeandle.safepoint_poll()

define void @two_dominating_polls(i64 %n) "java-method" {
entry:
  %nonempty = icmp sgt i64 %n, 0
  br i1 %nonempty, label %preheader, label %return

preheader:
  br label %header

header:
  %iv = phi i64 [ 0, %preheader ], [ %iv.next, %latch ]
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 1, i64 %iv) ]
  br label %latch

latch:
  %iv.next = add nuw nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 2, i64 %iv.next) ]
  %continue = icmp slt i64 %iv.next, %n
  br i1 %continue, label %header, label %loop.exit

loop.exit:
  br label %return

return:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @two_dominating_polls(
; CHECK-NOT:   call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       header.outer.latch:
; CHECK:         call hotspotcc void @jeandle.safepoint_poll()
; CHECK-SAME:      [ "deopt"(i32 2, i64 %outer.iv.next) ]
; CHECK-NOT:   call hotspotcc void @jeandle.safepoint_poll()
