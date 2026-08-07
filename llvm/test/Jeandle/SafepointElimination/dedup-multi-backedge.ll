; RUN: opt -passes=safepoint-poll-elimination -S < %s | FileCheck %s

; Two backward branches (a `continue`-style shape) and no LoopSimplify run
; before this pass, so the loop has no unique latch. Keep-one must bail and
; both polls must survive: each covers only its own backedge path.

declare hotspotcc void @jeandle.safepoint_poll()

define void @two_backedges(i64 %n, i1 %c) "java-method" gc "safepoint-in-loop-example" {
entry:
  br label %loop.header

loop.header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next.a, %back.a ], [ %iv.next.b, %back.b ]
  %body.cond = icmp slt i64 %iv, %n
  br i1 %body.cond, label %body, label %exit

body:
  br i1 %c, label %back.a, label %back.b

back.a:
  call hotspotcc void @jeandle.safepoint_poll()
  %iv.next.a = add nsw i64 %iv, 1
  br label %loop.header

back.b:
  call hotspotcc void @jeandle.safepoint_poll()
  %iv.next.b = add nsw i64 %iv, 2
  br label %loop.header

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @two_backedges(
; CHECK:       back.a:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       back.b:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
