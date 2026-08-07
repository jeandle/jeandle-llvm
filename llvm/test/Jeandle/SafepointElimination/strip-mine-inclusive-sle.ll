; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal \
; RUN:   -disable-output < %s

; The masked limit proves fewer than INT_MAX backedges (<= 1e6) even though the
; IV is i64. With strip mining enabled such a loop is still wrapped so its
; time-to-safepoint is bounded to the chunk size: inner poll-free, one relocated
; poll on the outer back-edge. (The bounded trip no longer opts it out of strip
; mining, matching C2's treatment of int counted loops.)

declare hotspotcc void @jeandle.safepoint_poll()

define void @loop(i64 noundef %raw) "java-method" {
entry:
  %n = and i64 %raw, 1000000
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp sle i64 %iv, %n
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

; CHECK-LABEL: @loop(
; CHECK:         .outer
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}}
; CHECK:       attributes #{{[0-9]+}} = { "jeandle.strip-mined-poll" }
