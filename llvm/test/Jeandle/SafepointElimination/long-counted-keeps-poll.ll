; RUN: opt -passes='safepoint-poll-elimination,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -jeandle-loop-strip-mining-iter=0 -S < %s | FileCheck %s

; A LONG counted loop (i64 IV) is NOT an int counted loop, so with strip
; mining off it must KEEP its back-edge poll. C2 distinguishes T_INT (delete-all
; when LoopStripMiningIter==0, loopnode.cpp:4067-4074) from T_LONG
; (remove_safepoints(keep_one=true), always — loopnode.cpp:4079-4080): a long
; counted loop runs up to 2^63 iterations, far beyond any chunk budget, so it
; must keep a poll per iteration. Jeandle's isIntCountedLoop accepted any
; integer width, so a long counted loop was miscounted as int-counted and its
; poll stripped, leaving a potentially unbounded time-to-safepoint that the
; coverage verifier then false-accepted (it shares the same recognizer).

declare hotspotcc void @jeandle.safepoint_poll()

define void @long_counted_keeps_poll(i64 %n) "java-method" {
entry:
  br label %loop.header

loop.header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %loop.header ]
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv) ]
  %iv.next = add nsw i64 %iv, 1
  %exit.cond = icmp slt i64 %iv.next, %n
  br i1 %exit.cond, label %loop.header, label %exit

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @long_counted_keeps_poll(
; CHECK:      call hotspotcc void @jeandle.safepoint_poll()
