; RUN: opt -passes=safepoint-poll-elimination -S < %s | FileCheck %s
; RUN: opt -passes='verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=warn -S < %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=VERIFY

; A natural loop (header H, latch LT) encloses an irreducible two-entry cycle
; A<->B. LoopInfo sees only the natural loop, so keep-one would walk the latch
; dominator chain, keep the header poll, and erase the cycle's polls — leaving
; a thread that spins in A<->B with no safepoint. The whole-function
; irreducible-CFG bail must prevent that: all three polls survive. The verifier
; also skips the function because neither safepoint transform changes its loop
; polls.

declare hotspotcc void @jeandle.safepoint_poll()

define void @irreducible_inner(i64 %n, i1 %c1, i1 %c2, i1 %c3) "java-method" gc "safepoint-in-loop-example" {
entry:
  br label %H

H:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %LT ]
  call hotspotcc void @jeandle.safepoint_poll()
  br i1 %c1, label %A, label %B

A:
  call hotspotcc void @jeandle.safepoint_poll()
  br i1 %c2, label %B, label %LT

B:
  call hotspotcc void @jeandle.safepoint_poll()
  br i1 %c3, label %A, label %LT

LT:
  %iv.next = add nsw i64 %iv, 1
  %cond = icmp slt i64 %iv.next, %n
  br i1 %cond, label %H, label %exit

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @irreducible_inner(
; CHECK:       H:
; CHECK:         call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       A:
; CHECK:         call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       B:
; CHECK:         call hotspotcc void @jeandle.safepoint_poll()

; VERIFY-NOT: SafepointCoverageVerifier:
