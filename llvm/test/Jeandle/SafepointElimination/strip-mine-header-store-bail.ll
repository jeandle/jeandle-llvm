; RUN: opt -passes='safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s

; A store in the header ahead of the exit test would be replayed when a batch
; boundary re-enters the header with the same IV. The transform must bail and
; keep the original poll.

declare hotspotcc void @jeandle.safepoint_poll()

define void @hdr_store(i64 %n, ptr %log) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  store i64 %iv, ptr %log
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

!java-method-compilation = !{}

; CHECK-LABEL: @hdr_store(
; CHECK-NOT:   outer
; CHECK:       store i64 %iv, ptr %log
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
