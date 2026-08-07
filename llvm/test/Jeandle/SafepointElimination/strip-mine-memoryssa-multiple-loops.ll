; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify' \
; RUN:   -S < %s > %t
; RUN: FileCheck %s --input-file=%t
; RUN: FileCheck %s --input-file=%t --check-prefix=OUTERS

declare hotspotcc void @jeandle.safepoint_poll()

define void @two_safe_loops(i64 %n) "java-method" {
entry:
  br label %h1
h1:
  %i = phi i64 [ 0, %entry ], [ %i.next, %l1 ]
  %c1 = icmp slt i64 %i, %n
  br i1 %c1, label %b1, label %between
b1:
  %i.next = add i64 %i, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %i.next) ]
  br label %l1
l1:
  br label %h1
between:
  br label %h2
h2:
  %j = phi i64 [ 0, %between ], [ %j.next, %l2 ]
  %c2 = icmp slt i64 %j, %n
  br i1 %c2, label %b2, label %exit
b2:
  %j.next = add i64 %j, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %j.next) ]
  br label %l2
l2:
  br label %h2
exit:
  ret void
}

; CHECK-LABEL: @two_safe_loops(
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll()
; CHECK:         call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll()
; CHECK:         call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll()

; OUTERS-LABEL: @two_safe_loops(
; OUTERS-DAG:   b1.outer:
; OUTERS-DAG:   b2.outer:
; OUTERS-LABEL: @safe_then_unsafe_loop(

define void @safe_then_unsafe_loop(i64 %n, ptr %p) "java-method" {
entry:
  br label %h1
h1:
  %i = phi i64 [ 0, %entry ], [ %i.next, %l1 ]
  %c1 = icmp slt i64 %i, %n
  br i1 %c1, label %b1, label %between
b1:
  %i.next = add i64 %i, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %i.next) ]
  br label %l1
l1:
  br label %h1
between:
  br label %h2
h2:
  %j = phi i64 [ 0, %between ], [ %j.next, %l2 ]
  %c2 = icmp slt i64 %j, %n
  br i1 %c2, label %b2, label %exit
b2:
  %j.next = add i64 %j, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %j.next) ]
  store volatile i64 %j, ptr %p
  br label %l2
l2:
  br label %h2
exit:
  ret void
}

; CHECK-LABEL: @safe_then_unsafe_loop(
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %j.next) ]
; CHECK-NEXT:  store volatile i64 %j{{[0-9]*}}, ptr %p
; CHECK:       b1.outer:
; CHECK-NOT:   b2.outer

!java-method-compilation = !{}
