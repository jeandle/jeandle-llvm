; RUN: opt -passes='safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' \
; RUN:   -jeandle-loop-strip-mining-iter=3000000000 -S < %s | FileCheck %s

; A normal `for (int i = start; i < n; i++)` (i32 IV from an unknown start, so
; SCEV gives no constant trip bound and short-loop deletion leaves it alone).
; The per-batch stride is |step| * chunk-iters; with a budget of 3e9 that does
; not fit the i32 IV as a positive stride (it sits between 2^31 and 2^32), which
; would overflow the saturating-clamp arithmetic. The pass must bail and leave
; the loop and its poll untouched rather than miscompile. This is the only
; realistically reachable trigger for the overflow guard: a clean i32/i64 IV
; whose budget fits would instead be short-loop-deletable before mining runs.

declare hotspotcc void @jeandle.safepoint_poll()

define void @f(i32 %n, i32 %start) "java-method" {
entry:
  br label %h

h:
  %iv = phi i32 [ %start, %entry ], [ %iv.next, %lat ]
  %c = icmp slt i32 %iv, %n
  br i1 %c, label %b, label %x

b:
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 5, i32 %iv.next) ]
  br label %lat

lat:
  br label %h

x:
  ret void
}

!java-method-compilation = !{}

; No outer loop is formed; the poll stays in the body with its original deopt
; bundle, and nothing is tagged as relocated coverage.
; CHECK-LABEL: @f(
; CHECK-NOT:   outer
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 5, i32 %iv.next) ]
