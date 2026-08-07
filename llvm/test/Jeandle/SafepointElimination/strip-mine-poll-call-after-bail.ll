; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' \
; RUN:   -S < %s | FileCheck %s

declare hotspotcc void @jeandle.safepoint_poll()
declare void @readonly_call(ptr) memory(read) nounwind

; A readonly non-safepoint call is a MemoryUse. Like C2's leaf-call case, it
; does not change the memory state observed at the backedge and does not block
; relocation.
define void @readonly_call_after_poll_is_allowed(i64 %n, ptr %p) "java-method" {
entry:
  br label %header
header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp slt i64 %iv, %n
  br i1 %cond, label %body, label %exit
body:
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  call void @readonly_call(ptr %p)
  br label %latch
latch:
  br label %header
exit:
  ret void
}

; CHECK-LABEL: @readonly_call_after_poll_is_allowed(
; CHECK:       body.outer:
; CHECK:       body.outer.latch:
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()

!java-method-compilation = !{}
