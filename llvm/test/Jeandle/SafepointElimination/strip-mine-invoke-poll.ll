; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>,verify' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -verify-each -S < %s | FileCheck %s
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>,verify' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -verify-each -S < %s | FileCheck %s

; Real-frontend shape: a body reduction and next IV are captured at the poll.
; Inlining into an invoke gives that poll its caller's unwind continuation.
; The new invoke must remain an invoke on the actual outer backedge, with the
; next-iteration deopt values remapped and the original EH destination intact.
; This test intentionally does not claim runtime async-exception/GC coverage.

declare hotspotcc void @jeandle.safepoint_poll()

define i64 @sum_invoke(i64 noundef %n, ptr addrspace(1) %obj) "java-method"
    gc "hotspotgc" personality ptr null {
entry:
  br label %header
header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %sum = phi i64 [ 0, %entry ], [ %sum.next, %latch ]
  %more = icmp slt i64 %iv, %n
  br i1 %more, label %body, label %exit
body:
  %sum.next = add i64 %sum, %iv
  %iv.next = add i64 %iv, 1
  invoke hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 41, ptr addrspace(1) %obj, i64 %sum.next, i64 %iv.next) ]
      to label %latch unwind label %unwind
latch:
  br label %header
unwind:
  %exception = landingpad i64 cleanup
  ret i64 -1
exit:
  %result = phi i64 [ %sum, %header ]
  ret i64 %result
}

; CHECK-LABEL: define i64 @sum_invoke(
; CHECK:       body:
; CHECK-NOT:     @jeandle.safepoint_poll
; CHECK:         br label %latch
; CHECK:       unwind:
; CHECK-SAME:     preds = %body.outer.latch
; CHECK-NEXT:     %exception = landingpad i64
; CHECK:       body.outer.latch:
; CHECK:         invoke hotspotcc void @jeandle.safepoint_poll() #[[POLL_ATTR:[0-9]+]] [ "deopt"(i32 41, ptr addrspace(1) %obj, i64 %{{[^,]+}}.outer.next, i64 %outer.iv.next) ]
; CHECK-NEXT:       to label %body.outer unwind label %unwind

; Original call support remains a control: no EH edge is invented.
define i64 @sum_call(i64 noundef %n) "java-method" {
entry:
  br label %header
header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %sum = phi i64 [ 0, %entry ], [ %sum.next, %latch ]
  %more = icmp slt i64 %iv, %n
  br i1 %more, label %body, label %exit
body:
  %sum.next = add i64 %sum, %iv
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i64 %sum.next, i64 %iv.next) ]
  br label %latch
latch:
  br label %header
exit:
  %result = phi i64 [ %sum, %header ]
  ret i64 %result
}

; CHECK-LABEL: define i64 @sum_call(
; CHECK:       body.outer.latch:
; CHECK:         call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    br label %body.outer

!java-method-compilation = !{}

; CHECK: attributes #[[POLL_ATTR]] = { {{.*}}"jeandle.strip-mined-poll"{{.*}} }
