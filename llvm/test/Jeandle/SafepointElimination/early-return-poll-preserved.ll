; RUN: opt -passes='safepoint-poll-elimination,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' \
; RUN:   -S < %s | FileCheck %s

; A poll in a block that is not part of the loop must never enter the loop's
; deletion candidate set, even when the loop's own poll is removed. Here a
; conditional early return inside a short loop is that block: the frontend
; emits a poll before every return (see add_safepoint_poll on return
; bytecodes), and the return block leaves the method — no path back to the
; back-edge — so it is outside the loop's blocks. The loop's trip count is a
; provable constant (100) within the chunk budget, so its back-edge poll is
; deleted (strip mining on → Early skips loop deletion and the StripMining
; mode's complete-deletion pass removes it), while the return poll survives
; untouched.

declare hotspotcc void @jeandle.safepoint_poll()

define void @early_return(ptr %a, i1 %stop) "java-method" gc "safepoint-in-loop-example" {
entry:
  br label %loop.header

loop.header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %loop.latch ]
  br i1 %stop, label %ret.block, label %loop.latch

loop.latch:
  call hotspotcc void @jeandle.safepoint_poll()
  %p = getelementptr inbounds i32, ptr %a, i64 %iv
  store i32 0, ptr %p
  %iv.next = add nuw nsw i64 %iv, 1
  %exit.cond = icmp slt i64 %iv.next, 100
  br i1 %exit.cond, label %loop.header, label %exit

ret.block:
  call hotspotcc void @jeandle.safepoint_poll()
  ret void

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @early_return(
; CHECK:       loop.latch:
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll
; CHECK:       ret.block:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    ret void
