; RUN: opt -passes='loop-simplify,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s
; RUN: opt -passes='loop-simplify,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' -jeandle-verify-safepoint-coverage=fatal -disable-output < %s

; The canonical Java `for (int i = 0; i < n; i++)` shape can run up to INT_MAX
; trips. With strip mining enabled it must be wrapped so its time-to-safepoint is
; bounded to the chunk size: the inner loop runs poll-free (<= N iterations), and
; a single relocated poll on the outer back-edge keeps coverage. Deleting its polls
; outright (the old int-counted-equivalent shortcut) left it poll-free for up to
; ~2^31 iterations.

declare hotspotcc void @jeandle.safepoint_poll()

define void @count(i32 %n, ptr %a) "java-method" {
entry:
  br label %header

header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp slt i32 %iv, %n
  br i1 %cond, label %body, label %exit

body:
  %p = getelementptr inbounds i32, ptr %a, i32 %iv
  store i32 %iv, ptr %p
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 5, i32 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @count(
; CHECK:         .outer
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #[[POLLATTR:[0-9]+]]
; CHECK:       attributes #[[POLLATTR]] = { "jeandle.strip-mined-poll" }

