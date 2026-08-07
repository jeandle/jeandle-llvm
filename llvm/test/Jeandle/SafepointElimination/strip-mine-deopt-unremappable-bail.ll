; RUN: opt -passes='safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s

; The poll's deopt bundle references %t, a body-computed value that is neither
; loop-invariant, a header phi, nor any header phi's latch-carried next value.
; It has no counterpart on the outer back-edge, so strip mining declines rather
; than emit a poll with an operand that doesn't dominate the outer latch. This
; is the genuinely-un-remappable case (contrast strip-mine-deopt-next-remap.ll,
; where the .next value IS remappable).

declare hotspotcc void @jeandle.safepoint_poll()

define i64 @sum(i64 %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %s  = phi i64 [ 0, %entry ], [ %s.next, %latch ]
  %cond = icmp slt i64 %iv, %n
  br i1 %cond, label %body, label %exit

body:
  %s.next = add i64 %s, %iv
  %t = mul i64 %iv, 7
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next, i64 %t) ]
  br label %latch

latch:
  br label %header

exit:
  %s.lcssa = phi i64 [ %s, %header ]
  ret i64 %s.lcssa
}

!java-method-compilation = !{}

; %t is not remappable, so no outer loop is created and the poll stays untouched.
; CHECK-LABEL: @sum(
; CHECK-NOT:   outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next, i64 %t) ]
