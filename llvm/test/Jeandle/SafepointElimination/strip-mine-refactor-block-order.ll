; RUN: opt -passes='loop-simplify,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s
; RUN: opt -passes='loop-simplify,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' -jeandle-verify-safepoint-coverage=fatal -disable-output < %s

; Pinning test for the strip-mining refactor (review §5.E.3). The outer wrapper
; loop built by createOuterSkeleton must produce its four blocks in a fixed
; creation order — preheader, header, inner-entry, latch — and buildOuterLatch
; plus relocatePollToOuterLatch must keep the outer-latch instruction sequence
; as: batch-boundary phi -> relocated poll -> back-edge branch. A regression that
; reorders block creation or latch instructions surfaces here. The input is the
; canonical runtime-bound counted loop, which yields a pre-tested outer loop.

declare hotspotcc void @jeandle.safepoint_poll()

define void @count(i32 noundef %n, ptr %a) "java-method" {
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
; The four outer blocks appear in creation order. `outer:` (colon right after
; "outer") matches only the bare outer-header label, not the suffixed siblings.
; The latch (last) immediately opens with the batch-boundary phi, then the
; relocated poll, then the back-edge branch (pre-tested => no outer.cond).
; CHECK: outer.ph:
; CHECK: outer:
; CHECK: outer.inner.entry:
; CHECK: outer.latch:
; CHECK-NEXT: %outer.iv.next = phi
; CHECK: call hotspotcc void @jeandle.safepoint_poll() #[[POLLATTR:[0-9]+]]
; CHECK: br label %{{.*}}.outer
; CHECK: attributes #[[POLLATTR]] = { "jeandle.strip-mined-poll" }
