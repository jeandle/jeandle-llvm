; RUN: opt -verify-each \
; RUN:   -passes='function(safepoint-poll-elimination<loop-deletion-prep>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>,safepoint-poll-elimination<loop-deletion-prep>,verify<jeandle-safepoint-coverage>)' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal \
; RUN:   -S < %s \
; RUN:   | FileCheck %s --check-prefix=ATOMIC
; RUN: opt -verify-each \
; RUN:   -passes='function(early-cse,instcombine,loop-simplify,lcssa,safepoint-poll-elimination<loop-deletion-prep>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>,safepoint-poll-elimination<loop-deletion-prep>),java-operation-lower<phase=1>,default<O3>,rewrite-statepoints-for-gc,verify' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal \
; RUN:   -S < %s | FileCheck %s --check-prefix=O3
; RUN: opt -verify-each \
; RUN:   -passes='function(verify<jeandle-safepoint-coverage>,safepoint-poll-elimination<loop-deletion-prep>,verify<jeandle-safepoint-coverage>)' \
; RUN:   -jeandle-loop-strip-mining-iter=0 \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -S < %s \
; RUN:   | FileCheck %s --check-prefix=NO-STRIP

; Minimized from the strip-mining pass entry IR for:
;
;   for (int i = 0; i < n; i++) { }
;   return n ^ 0x5a5a5a5aL;
;
; The final IV remains live only in the return poll's deopt state. Jeandle
; materializes that exit value and deletes the empty loop together with its
; poll, so no pass boundary exposes an uncovered loop.

declare hotspotcc void @jeandle.safepoint_poll()

define i64 @deletes_rotated_empty_loop(i32 %n, ptr %slot) "java-method" {
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
  %final.loop = phi i32 [ %iv.next, %loop ]
  br label %exit

exit:
  %final = phi i32 [ 0, %entry ], [ %final.loop, %loop.exit ]
  %result32 = xor i32 %n, 1515870810
  %result = sext i32 %result32 to i64
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 19, i32 %n, i32 %final, i64 %result, ptr %slot) ]
  ret i64 %result
}

; ATOMIC-LABEL: @deletes_rotated_empty_loop(
; ATOMIC-NOT:   loop:
; ATOMIC-NOT:   %iv = phi
; ATOMIC:       call hotspotcc void @jeandle.safepoint_poll()

; NO-STRIP-LABEL: @deletes_rotated_empty_loop(
; NO-STRIP-NOT:   loop:
; NO-STRIP-NOT:   %iv = phi
; NO-STRIP:       call hotspotcc void @jeandle.safepoint_poll()

; O3-LABEL: @deletes_rotated_empty_loop(
; O3-NOT:   loop:
; O3-NOT:   %iv = phi
; O3-NOT:   jeandle.strip-mined-poll
; O3:       call hotspotcc void @jeandle.safepoint_poll()

; This is the earlier frontend shape. Loop rotation and LICM mutate it into the
; do-while form above before the production strip-mining pass runs.
define i64 @deletes_pipeline_mutated_frontend_loop(i32 %n, ptr %slot) "java-method" {
entry:
  br label %header

header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %body ]
  %done = icmp sge i32 %iv, %n
  br i1 %done, label %exit, label %body

body:
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 10, i32 %n, i32 %iv.next, ptr %slot) ]
  br label %header

exit:
  %final = phi i32 [ %iv, %header ]
  %result32 = xor i32 %n, 1515870810
  %result = sext i32 %result32 to i64
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 19, i32 %n, i32 %final, i64 %result, ptr %slot) ]
  ret i64 %result
}

; ATOMIC-LABEL: @deletes_pipeline_mutated_frontend_loop(
; ATOMIC-NOT:   header:
; ATOMIC-NOT:   %iv = phi
; ATOMIC:       call hotspotcc void @jeandle.safepoint_poll()

; O3-LABEL: @deletes_pipeline_mutated_frontend_loop(
; O3-NOT:   header:
; O3-NOT:   %iv = phi
; O3-NOT:   jeandle.strip-mined-poll
; O3:       call hotspotcc void @jeandle.safepoint_poll()

; The inner poll is the only safepoint that dominates the unbounded outer
; latch. Deleting the inner loop would uncover the outer loop, so retain it.
define void @keeps_empty_loop_required_by_unbounded_ancestor(i32 %n) "java-method" {
entry:
  br label %outer.header

outer.header:
  %state = phi i32 [ 0, %entry ], [ %final, %outer.latch ]
  br label %inner.preheader

inner.preheader:
  br label %inner.loop

inner.loop:
  %iv = phi i32 [ 0, %inner.preheader ], [ %iv.next, %inner.loop ]
  %iv.next = add nuw nsw i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 %iv.next, i32 %state) ]
  %continue = icmp slt i32 %iv.next, %n
  br i1 %continue, label %inner.loop, label %outer.latch

outer.latch:
  %final = phi i32 [ %iv.next, %inner.loop ]
  br label %outer.header
}

; ATOMIC-LABEL: @keeps_empty_loop_required_by_unbounded_ancestor(
; ATOMIC:       inner.loop:
; ATOMIC:         call hotspotcc void @jeandle.safepoint_poll()
; ATOMIC:       outer.latch:
; ATOMIC-NEXT:    %final = phi i32
; ATOMIC-NEXT:    br label %outer.header

; Once the outer loop has independent all-path coverage, the inner empty loop
; can be removed without weakening time-to-safepoint coverage.
define void @deletes_empty_loop_when_ancestor_has_own_poll(i32 %n) "java-method" {
entry:
  br label %outer.header

outer.header:
  br label %inner.preheader

inner.preheader:
  br label %inner.loop

inner.loop:
  %iv = phi i32 [ 0, %inner.preheader ], [ %iv.next, %inner.loop ]
  %iv.next = add nuw nsw i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %continue = icmp slt i32 %iv.next, %n
  br i1 %continue, label %inner.loop, label %outer.latch

outer.latch:
  %final = phi i32 [ %iv.next, %inner.loop ]
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %final) ]
  br label %outer.header
}

; ATOMIC-LABEL: @deletes_empty_loop_when_ancestor_has_own_poll(
; ATOMIC-NOT:   inner.loop:
; ATOMIC:       outer.latch:
; ATOMIC-NEXT:    %final = phi i32
; ATOMIC-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; ATOMIC-NEXT:    br label %outer.header

; A real memory side effect is not an empty loop even when the stored value is
; invariant. The loop and some safepoint coverage must remain.
define void @keeps_loop_with_store(i32 %n, ptr %out) "java-method" {
entry:
  %positive = icmp sgt i32 %n, 0
  br i1 %positive, label %preheader, label %exit

preheader:
  br label %loop

loop:
  %iv = phi i32 [ 0, %preheader ], [ %iv.next, %loop ]
  store volatile i32 %iv, ptr %out, align 4
  %iv.next = add nuw nsw i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %continue = icmp slt i32 %iv.next, %n
  br i1 %continue, label %loop, label %exit

exit:
  ret void
}

; ATOMIC-LABEL: @keeps_loop_with_store(
; ATOMIC:         store volatile i32
; ATOMIC:         call hotspotcc void @jeandle.safepoint_poll()

; This pure recurrence contributes to the return value but has no SCEV exit
; expression. Conservatively retain the loop instead of guessing its live-out.
define i32 @keeps_loop_with_unrepresentable_liveout(i32 %n) "java-method" {
entry:
  %positive = icmp sgt i32 %n, 0
  br i1 %positive, label %preheader, label %exit.zero

preheader:
  br label %loop

loop:
  %iv = phi i32 [ 0, %preheader ], [ %iv.next, %loop ]
  %acc = phi i32 [ 7, %preheader ], [ %acc.next, %loop ]
  %acc.next = xor i32 %acc, %iv
  %iv.next = add nuw nsw i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %continue = icmp slt i32 %iv.next, %n
  br i1 %continue, label %loop, label %exit.loop

exit.loop:
  %result = phi i32 [ %acc.next, %loop ]
  ret i32 %result

exit.zero:
  ret i32 7
}

; ATOMIC-LABEL: @keeps_loop_with_unrepresentable_liveout(
; ATOMIC:         %acc.next = xor i32
; ATOMIC:         .outer
; ATOMIC:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}}

; A droppable intrinsic may still report memory side effects, so the atomic
; empty-loop deletion retains the loop. The llvm.assume is also a relocation
; hazard, so the loop is not strip-mined and its back-edge poll is kept.
define void @keeps_loop_with_droppable_side_effect(i32 %len, ptr %slot) "java-method" {
entry:
  br label %loop

loop:
  %remaining = phi i32 [ %len, %entry ], [ %remaining.next, %latch ]
  %continue = icmp ugt i32 %remaining, 11
  br i1 %continue, label %latch, label %exit

latch:
  %remaining.next = add i32 %remaining, -12
  %assume.condition = icmp ne i32 %remaining.next, 123456789
  call void @llvm.assume(i1 %assume.condition)
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 10, i32 %remaining.next, ptr %slot) ]
  br label %loop

exit:
  %final = phi i32 [ %remaining, %loop ]
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 19, i32 %final, ptr %slot) ]
  ret void
}

; ATOMIC-LABEL: @keeps_loop_with_droppable_side_effect(
; ATOMIC:       latch:
; ATOMIC:         %remaining.next = add i32 %remaining, -12
; ATOMIC-NEXT:    %assume.condition = icmp ne i32 %remaining.next, 123456789
; ATOMIC-NEXT:    call void @llvm.assume(i1 %assume.condition)
; ATOMIC-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; ATOMIC-NEXT:    br label %loop
; ATOMIC-NOT:     jeandle.strip-mined-poll
; ATOMIC:       exit:
; ATOMIC:         call hotspotcc void @jeandle.safepoint_poll()

; O3-LABEL: @keeps_loop_with_droppable_side_effect(
; O3:       latch:
; O3:         call void @llvm.assume
; O3-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; O3-NEXT:    %continue = icmp ugt i32
; O3-NEXT:    br i1 %continue, label %latch, label %exit
; O3-NOT:     jeandle.strip-mined-poll
; O3:       exit:
; O3:         call hotspotcc void @jeandle.safepoint_poll()

; NO-STRIP-LABEL: @keeps_loop_with_droppable_side_effect(
; NO-STRIP:       latch:
; NO-STRIP:         call void @llvm.assume
; NO-STRIP-NEXT:    call hotspotcc void @jeandle.safepoint_poll()

; Choosing among multiple exits would require preserving the loop's control
; semantics. This initial capability deliberately handles one dedicated exit.
define i32 @keeps_empty_loop_with_multiple_exits(i32 %n, i1 %stop) "java-method" {
entry:
  br label %loop

loop:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %latch ]
  br i1 %stop, label %early.exit, label %latch

latch:
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %continue = icmp slt i32 %iv.next, %n
  br i1 %continue, label %loop, label %normal.exit

early.exit:
  ret i32 %iv

normal.exit:
  ret i32 %iv.next
}

; ATOMIC-LABEL: @keeps_empty_loop_with_multiple_exits(
; ATOMIC:       loop:
; ATOMIC:         br i1 %stop
; ATOMIC:       latch:
; ATOMIC:         call hotspotcc void @jeandle.safepoint_poll()

!java-method-compilation = !{}

; ATOMIC:       attributes #{{[0-9]+}} = { "jeandle.strip-mined-poll" }
