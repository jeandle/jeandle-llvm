; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' \
; RUN:   -S < %s | FileCheck %s
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -jeandle-loop-strip-mining-iter=0 \
; RUN:   -S < %s | FileCheck %s --check-prefix=DISABLED \
; RUN:   --implicit-check-not=.outer

; The StripMining mode runs the complete loop-tree poll deletion
; (completeLoopPollDeletion) AFTER its (possibly empty) surgery: a non-counted
; loop reduces its polls via keep-one; a constant-short counted loop's poll is
; deleted outright (short-loop); a strip-minable int counted loop relocates its
; poll to the outer back-edge (the inner is poll-free). With strip mining OFF
; (-iter=0) the mode is a no-op (polls unchanged, no .outer nest) and
; the deletion falls to the Early mode instead.

declare hotspotcc void @jeandle.safepoint_poll()

define void @non_counted_keep_one(i1 %again) "java-method" {
entry:
  br label %header
header:
  call hotspotcc void @jeandle.safepoint_poll()
  br label %body
body:
  call hotspotcc void @jeandle.safepoint_poll()
  br i1 %again, label %header, label %exit
exit:
  ret void
}

; CHECK-LABEL: @non_counted_keep_one(
; CHECK-COUNT-1: call hotspotcc void @jeandle.safepoint_poll()

define void @short_counted_poll_deleted() "java-method" {
entry:
  br label %header
header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp slt i64 %iv, 4
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

; CHECK-LABEL: @short_counted_poll_deleted(
; CHECK-NOT:   .outer
; CHECK-NOT:   call hotspotcc void @jeandle.safepoint_poll

define void @strip_mining_toggle(i64 %n) "java-method" {
entry:
  br label %header
header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp slt i64 %iv, %n
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

; DISABLED-LABEL: @strip_mining_toggle(
; DISABLED:       body:
; DISABLED:         call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]

; CHECK-LABEL: @strip_mining_toggle(
; CHECK:       body:
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll
; CHECK:       body.outer.latch:
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}} [ "deopt"(i64 %outer.iv.next) ]

!java-method-compilation = !{}
