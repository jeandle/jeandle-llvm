; RUN: opt -verify-each \
; RUN:   -passes='function(verify<jeandle-safepoint-coverage>,safepoint-poll-elimination<loop-deletion-prep>,verify<jeandle-safepoint-coverage>)' \
; RUN:   -jeandle-loop-strip-mining-iter=0 \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -S < %s \
; RUN:   | FileCheck %s

; Nested empty loops: once the inner loop is deleted, the outer loop becomes an
; innermost empty loop carrying only its own poll. LoopDeletionPrep must revisit
; it in the same run and cascade the deletion (C2 removes such nests wholesale;
; a single innermost-only pass over a stale snapshot cannot).

declare hotspotcc void @jeandle.safepoint_poll()

define void @cascade_delete_nested_empty_loops(i32 %n, i32 %m, ptr %slot) "java-method" {
entry:
  br label %outer.ph

outer.ph:
  br label %outer

outer:
  %i = phi i32 [ 0, %outer.ph ], [ %i.next, %outer.latch ]
  br label %inner.ph

inner.ph:
  br label %inner

inner:
  %j = phi i32 [ 0, %inner.ph ], [ %j.next, %inner ]
  %j.next = add nuw nsw i32 %j, 1
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 10, i32 %n, i32 %m, i32 %j.next, ptr %slot) ]
  %j.cont = icmp slt i32 %j.next, %m
  br i1 %j.cont, label %inner, label %inner.exit

inner.exit:
  %j.final = phi i32 [ %j.next, %inner ]
  br label %outer.latch

outer.latch:
  %i.next = add nuw nsw i32 %i, 1
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 20, i32 %n, i32 %m, i32 %j.final, i32 %i.next, ptr %slot) ]
  %i.cont = icmp slt i32 %i.next, %n
  br i1 %i.cont, label %outer, label %outer.exit

outer.exit:
  %i.final = phi i32 [ %i.next, %outer.latch ]
  br label %exit

exit:
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 30, i32 %n, i32 %m, i32 %i.final, ptr %slot) ]
  ret void
}

; CHECK-LABEL: @cascade_delete_nested_empty_loops(
; CHECK-NOT:   %j = phi
; CHECK-NOT:   %i = phi
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       ret void

; An LCSSA exit phi with no uses at all is dead state, not a live-out; it must
; not block deletion of an otherwise empty loop. The second exit phi keeps the
; loop in scope via the return poll's deopt state.
define void @deletes_empty_loop_with_dead_exit_phi(i32 %n, ptr %slot) "java-method" {
entry:
  %positive = icmp sgt i32 %n, 0
  br i1 %positive, label %preheader, label %exit

preheader:
  br label %loop

loop:
  %iv = phi i32 [ 0, %preheader ], [ %iv.next, %loop ]
  %iv.next = add nuw nsw i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 10, i32 %n, i32 %iv.next, ptr %slot) ]
  %continue = icmp slt i32 %iv.next, %n
  br i1 %continue, label %loop, label %loop.exit

loop.exit:
  %final.dead = phi i32 [ %iv.next, %loop ]
  %final.live = phi i32 [ %iv.next, %loop ]
  br label %exit

exit:
  %final = phi i32 [ 0, %entry ], [ %final.live, %loop.exit ]
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 19, i32 %n, i32 %final, ptr %slot) ]
  ret void
}

; CHECK-LABEL: @deletes_empty_loop_with_dead_exit_phi(
; CHECK-NOT:   %iv = phi
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       ret void
