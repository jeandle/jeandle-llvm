; RUN: opt -passes=safepoint-elimination -S < %s | FileCheck %s

; An i32 counted loop with an unknown (parameter) upper bound. SCEV cannot give
; a concrete max backedge-taken count smaller than -jeandle-short-loop-max-iter,
; only a 32-bit one (INT_MAX). With the default config
; (-jeandle-sp-elim-32bit-range=false) the loop is classified Unbounded and the
; back-edge safepoint poll is preserved, because there is no strip-mining
; transform yet to bound GC latency on a 2^32-iter loop.
;
; The counted-loop-basic / counted-loop-nonzero-init / counted-loop-step2 etc.
; fixtures cover the opt-in case (-jeandle-sp-elim-32bit-range=true).

declare hotspotcc void @jeandle.safepoint_poll()

define void @i32_unknown_bound(i32 %n) gc "safepoint-in-loop-example" {
entry:
  %cmp = icmp sgt i32 %n, 0
  br i1 %cmp, label %loop.header, label %exit

loop.header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop.latch ]
  %exit.cond = icmp slt i32 %iv, %n
  br i1 %exit.cond, label %loop.body, label %exit

loop.body:
  call hotspotcc void @jeandle.safepoint_poll()
  %val = load i32, ptr null
  br label %loop.latch

loop.latch:
  %iv.next = add nsw i32 %iv, 1
  br label %loop.header

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @i32_unknown_bound(
; CHECK:       loop.body:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
