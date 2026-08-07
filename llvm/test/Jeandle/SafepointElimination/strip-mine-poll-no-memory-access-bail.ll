; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' \
; RUN:   -S < %s | FileCheck %s

; Production polls are MemoryDefs. A synthetic memory(none) poll has no
; MemorySSA access from which to prove the batch-boundary state and therefore
; fails closed.

declare hotspotcc void @jeandle.safepoint_poll() memory(none)

define void @poll_without_memory_access_bails(i64 %n) "java-method" {
entry:
  br label %header
header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp slt i64 %iv, %n
  br i1 %cond, label %body, label %exit
body:
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll()
  br label %latch
latch:
  br label %header
exit:
  ret void
}

; CHECK-LABEL: @poll_without_memory_access_bails(
; CHECK-NOT:   .outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()

!java-method-compilation = !{}
