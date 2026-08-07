; RUN: opt -verify-each \
; RUN:   -passes='function(verify<jeandle-safepoint-coverage>,safepoint-poll-elimination<loop-deletion-prep>,verify<jeandle-safepoint-coverage>)' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -S < %s \
; RUN:   | FileCheck %s
; RUN: opt -verify-each \
; RUN:   -passes='function(safepoint-strip-mining<strip-mining;defer-empty-loop-deletion>,safepoint-poll-elimination<after-strip-mining;defer-empty-loop-deletion>)' \
; RUN:   -S < %s | FileCheck %s --check-prefix=DEFER

; LoopDeletionPrep deletes a fully empty loop nest as one transaction. The
; deepest poll is required by both long ancestors, so deleting innermost loops
; one at a time cannot make progress without temporarily uncovering an outer
; loop. Deleting the outermost proven-empty nest removes all three loops and
; the poll atomically.

declare hotspotcc void @jeandle.safepoint_poll()

define void @delete_empty_nest_with_cross_loop_poll_dependency() "java-method" {
entry:
  br label %outer

outer:
  %i = phi i32 [ 0, %entry ], [ %i.next, %outer.latch ]
  br label %middle

middle:
  %j = phi i32 [ 0, %outer ], [ %j.next, %middle.latch ]
  br label %inner

inner:
  %k = phi i32 [ 0, %middle ], [ %k.next, %inner ]
  %k.next = add nuw nsw i32 %k, 1
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 %i, i32 %j, i32 %k.next) ]
  %k.cont = icmp ult i32 %k.next, 2
  br i1 %k.cont, label %inner, label %middle.latch

middle.latch:
  %j.next = add nuw nsw i32 %j, 1
  %j.cont = icmp ult i32 %j.next, 2002
  br i1 %j.cont, label %middle, label %outer.latch

outer.latch:
  %i.next = add nuw nsw i32 %i, 1
  %i.cont = icmp ult i32 %i.next, 2002
  br i1 %i.cont, label %outer, label %outer.exit

outer.exit:
  %i.final = phi i32 [ %i.next, %outer.latch ]
  br label %exit

exit:
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %i.final) ]
  ret void
}

; CHECK-LABEL: @delete_empty_nest_with_cross_loop_poll_dependency(
; CHECK-NOT:   outer:
; CHECK-NOT:   middle:
; CHECK-NOT:   inner:
; CHECK-COUNT-1: call hotspotcc void @jeandle.safepoint_poll()

; DEFER-LABEL: @delete_empty_nest_with_cross_loop_poll_dependency(
; DEFER:       outer:
; DEFER:       middle:
; DEFER:       inner:
; DEFER:       call hotspotcc void @jeandle.safepoint_poll()

; An empty loop with no deopt-state live-out still has to lose its poll and be
; deleted. Leaving it for ordinary LoopDeletion cannot work while the poll is
; present.
define void @delete_empty_loop_without_deopt_liveout() "java-method" {
entry:
  br label %loop

loop:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop ]
  %iv.next = add nuw nsw i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %continue = icmp ult i32 %iv.next, 2002
  br i1 %continue, label %loop, label %exit

exit:
  ret void
}

; CHECK-LABEL: @delete_empty_loop_without_deopt_liveout(
; CHECK-NOT:   loop:
; CHECK-NOT:   call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       ret void

!java-method-compilation = !{}
