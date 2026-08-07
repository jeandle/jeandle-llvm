; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal \
; RUN:   -S < %s 2>&1 | FileCheck %s

; After strip mining, the inner loop runs poll-free with a bound SCEV can't
; recover (clamped select). The fatal coverage verifier must still pass: the
; relocated poll on the outer back-edge carries the "jeandle.strip-mined-poll"
; attribute that marks the nest (bounded by construction). A coverage violation
; would abort the compile, so reaching FileCheck at all proves the verifier
; accepted the nest.

declare hotspotcc void @jeandle.safepoint_poll()

define void @loop(i64 %n) "java-method" {
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

!java-method-compilation = !{}

; CHECK-NOT: SafepointCoverageVerifier
; CHECK:     call hotspotcc void @jeandle.safepoint_poll() #[[POLLATTR:[0-9]+]]
; CHECK:     attributes #[[POLLATTR]] = { "jeandle.strip-mined-poll" }
