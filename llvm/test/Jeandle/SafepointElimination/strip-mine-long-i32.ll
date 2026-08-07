; RUN: opt -passes='loop-simplify,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s
; RUN: opt -passes='loop-simplify,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' -jeandle-verify-safepoint-coverage=fatal -disable-output < %s

; An i64 IV with a provable trip count below INT_MAX (here 2e9) is still a large
; loop whose time-to-safepoint must be bounded. With strip mining enabled it is
; wrapped like any counted loop: inner poll-free (<= N iterations), one relocated
; poll on the outer back-edge. (IV width does not opt it out of strip mining.)

declare hotspotcc void @jeandle.safepoint_poll()

define void @r5(ptr %a) "java-method" {
entry:
  br label %h

h:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %lat ]
  %c = icmp slt i64 %iv, 2000000000
  br i1 %c, label %b, label %x

b:
  %p = getelementptr inbounds i32, ptr %a, i64 %iv
  store i32 0, ptr %p
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 5, i64 %iv.next) ]
  br label %lat

lat:
  br label %h

x:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @r5(
; CHECK:         .outer
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}}
; CHECK:       attributes #{{[0-9]+}} = { "jeandle.strip-mined-poll" }
