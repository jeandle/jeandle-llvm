; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>,verify' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -verify-each -S < %s | FileCheck %s

declare hotspotcc void @jeandle.safepoint_poll()

; EH PHIs need their own batch-boundary value plans. Refuse even a PHI that
; could theoretically be remapped; this is the deliberately narrow contract.
define i64 @eh_phi(i64 noundef %n) "java-method" personality ptr null {
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
      [ "deopt"(i64 %sum.next, i64 %iv.next) ]
      to label %latch unwind label %unwind
latch:
  br label %header
unwind:
  %exception.sum = phi i64 [ %sum.next, %body ]
  %exception = landingpad i64 cleanup
  ret i64 %exception.sum
exit:
  %result = phi i64 [ %sum, %header ]
  ret i64 %result
}

; CHECK-LABEL: define i64 @eh_phi(
; CHECK-NOT:   .outer
; CHECK:       invoke hotspotcc void @jeandle.safepoint_poll()
; CHECK:         to label %latch unwind label %unwind
; CHECK:       unwind:
; CHECK:       %exception.sum = phi i64
; CHECK-NOT:   .outer
; CHECK:       ret i64

; An iteration-local intermediate is not the next value of any header
; recurrence, so moving its deopt operand to a batch boundary is unsupported.
define i64 @unremappable_state(i64 noundef %n) "java-method" personality ptr null {
entry:
  br label %header
header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %more = icmp slt i64 %iv, %n
  br i1 %more, label %body, label %exit
body:
  %intermediate = mul i64 %iv, 7
  %iv.next = add i64 %iv, 1
  invoke hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i64 %intermediate, i64 %iv.next) ]
      to label %latch unwind label %unwind
latch:
  br label %header
unwind:
  %exception = landingpad i64 cleanup
  ret i64 -1
exit:
  ret i64 0
}

; CHECK-LABEL: define i64 @unremappable_state(
; CHECK-NOT:   .outer
; CHECK:       invoke hotspotcc void @jeandle.safepoint_poll()
; CHECK-SAME:    [ "deopt"(i64 %intermediate, i64 %iv.next) ]
; CHECK:         to label %latch unwind label %unwind
; CHECK-NOT:   .outer
; CHECK:       ret i64

; A mandatory first iteration with no entry-order proof requires a post-tested
; outer. Its conditional latch cannot be replaced by an invoke while retaining
; the current latch-local strip-mined-poll marker protocol, so keep the poll.
define void @post_tested(i32 noundef %n) "java-method" personality ptr null {
entry:
  br label %body
body:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %latch ]
  %iv.next = add nsw i32 %iv, 1
  invoke hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
      to label %latch unwind label %unwind
latch:
  %more = icmp slt i32 %iv.next, %n
  br i1 %more, label %body, label %exit
unwind:
  %exception = landingpad i64 cleanup
  ret void
exit:
  ret void
}

; CHECK-LABEL: define void @post_tested(
; CHECK-NOT:   .outer
; CHECK:       invoke hotspotcc void @jeandle.safepoint_poll()
; CHECK:         to label %latch unwind label %unwind
; CHECK-NOT:   .outer
; CHECK:       ret void

; Unknown operand-bundle semantics are not carried or fabricated by this
; narrow relocation. In particular, a funclet bundle needs a different EH
; plan rather than being silently dropped with an otherwise valid deopt state.
define void @unknown_bundle(i64 noundef %n) "java-method" personality ptr null {
entry:
  br label %header
header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %more = icmp slt i64 %iv, %n
  br i1 %more, label %body, label %exit
body:
  %iv.next = add i64 %iv, 1
  invoke hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i64 %iv.next), "unknown.poll.contract"(i32 7) ]
      to label %latch unwind label %unwind
latch:
  br label %header
unwind:
  %exception = landingpad i64 cleanup
  ret void
exit:
  ret void
}

; CHECK-LABEL: define void @unknown_bundle(
; CHECK-NOT:   .outer
; CHECK:       invoke hotspotcc void @jeandle.safepoint_poll()
; CHECK-SAME:    "unknown.poll.contract"(i32 7)
; CHECK:         to label %latch unwind label %unwind
; CHECK-NOT:   .outer
; CHECK:       ret void

; The clone cannot silently drop an attachment whose relocation contract is
; unknown, even when the deopt state and normal/unwind shape are supported.
define void @unknown_metadata(i64 noundef %n) "java-method" personality ptr null {
entry:
  %has.work = icmp sgt i64 %n, 0
  br i1 %has.work, label %preheader, label %empty
preheader:
  br label %header
header:
  %iv = phi i64 [ 0, %preheader ], [ %iv.next, %latch ]
  %iv.next = add nsw i64 %iv, 1
  invoke hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
      to label %latch unwind label %unwind, !unknown.poll.contract !0
latch:
  %more = icmp slt i64 %iv.next, %n
  br i1 %more, label %header, label %exit
unwind:
  %exception = landingpad i64 cleanup
  ret void
exit:
  ret void
empty:
  ret void
}
; CHECK-LABEL: define void @unknown_metadata(
; CHECK-NOT:   .outer
; CHECK:       invoke hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    to label %latch unwind label %unwind, !unknown.poll.contract
; CHECK-NOT:   .outer
; CHECK:       }

; A real funclet destination, not just an unknown bundle, remains unsupported.
declare i32 @__CxxFrameHandler3(...)
define void @funclet_handler(i64 noundef %n) "java-method"
    personality ptr @__CxxFrameHandler3 {
entry:
  %has.work = icmp sgt i64 %n, 0
  br i1 %has.work, label %preheader, label %empty
preheader:
  br label %header
header:
  %iv = phi i64 [ 0, %preheader ], [ %iv.next, %latch ]
  %iv.next = add nsw i64 %iv, 1
  invoke hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
      to label %latch unwind label %cleanup
latch:
  %more = icmp slt i64 %iv.next, %n
  br i1 %more, label %header, label %exit
cleanup:
  %pad = cleanuppad within none []
  cleanupret from %pad unwind to caller
exit:
  ret void
empty:
  ret void
}
; CHECK-LABEL: define void @funclet_handler(
; CHECK-NOT:   .outer
; CHECK:       invoke hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    to label %latch unwind label %cleanup
; CHECK:       cleanuppad within none
; CHECK-NOT:   .outer
; CHECK:       }

!java-method-compilation = !{}
!0 = !{i32 7}
