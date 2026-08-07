; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' \
; RUN:   -S < %s | FileCheck %s

; A MemoryUse poll does not advance memory. Its defining access is the state
; that must match the latch-to-header backedge, so it can be relocated when no
; MemoryDef follows it.

declare hotspotcc void @jeandle.safepoint_poll() memory(read)

define void @poll_memory_use_is_allowed(i64 %n) "java-method" {
entry:
  br label %header
header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp slt i64 %iv, %n
  br i1 %cond, label %body, label %exit
body:
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch
latch:
  br label %header
exit:
  ret void
}

; CHECK-LABEL: @poll_memory_use_is_allowed(
; CHECK:       body.outer:
; CHECK:       body.outer.latch:
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()

!java-method-compilation = !{}
