; RUN: opt -passes='safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s

; A loop with two back-edges (two latches) has no unique latch. Back-edge poll
; collection and the CFG surgery both key off a single latch, so strip mining
; must bail and leave the loop and its poll untouched.

declare hotspotcc void @jeandle.safepoint_poll()

define void @ml(i64 %n, i1 %p) "java-method" {
entry:
  br label %h

h:
  %iv = phi i64 [ 0, %entry ], [ %a, %la ], [ %b, %lb ]
  %c = icmp slt i64 %iv, %n
  br i1 %c, label %body, label %x

body:
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv) ]
  br i1 %p, label %la, label %lb

la:
  %a = add i64 %iv, 1
  br label %h

lb:
  %b = add i64 %iv, 2
  br label %h

x:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @ml(
; CHECK-NOT:   outer
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv) ]
