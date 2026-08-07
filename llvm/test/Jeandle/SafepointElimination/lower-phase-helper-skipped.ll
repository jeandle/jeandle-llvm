; RUN: opt -passes=safepoint-poll-elimination -S < %s | FileCheck %s
; RUN: opt -passes='verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=warn -disable-output < %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=VERIFY

; The compilation module is the template module, so it carries runtime helper
; bodies (lower-phase attribute) alongside the Java method. Helpers are runtime
; stubs with their own bounded loops; neither pass should touch them. @helper's
; adjacent polls must survive (transform gated), and its poll-free loop must
; not be reported (verifier gated) — only the real @java_method loop is.

declare hotspotcc void @jeandle.safepoint_poll()

define void @helper(i64 %n) "lower-phase"="1" gc "stub" {
entry:
  br label %loop

loop:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %loop ]
  call hotspotcc void @jeandle.safepoint_poll()
  call hotspotcc void @jeandle.safepoint_poll()
  %iv.next = add nsw i64 %iv, 1
  %c = icmp slt i64 %iv.next, %n
  br i1 %c, label %loop, label %exit

exit:
  ret void
}

define void @java_method(ptr %p) "java-method" gc "method" {
entry:
  br label %loop

loop:
  %v = load i32, ptr %p
  %c = icmp eq i32 %v, 0
  br i1 %c, label %loop, label %exit

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @helper(
; CHECK:         call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()

; VERIFY-NOT: function 'helper'
; VERIFY: loop with header 'loop' in function 'java_method'
