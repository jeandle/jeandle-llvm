; RUN: opt -passes='loop-simplify,lcssa,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>,verify' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -S < %s | FileCheck %s

; IndVarSimplify can widen a Java int induction to i64 while the backedge deopt
; state still needs the Java local as a trunc of the latch-carried next value.
; The cast is batch-boundary state and must be rebuilt from the outer IV.

declare hotspotcc void @jeandle.safepoint_poll()

define i64 @widened_iv_with_i32_deopt(i32 %limit) "java-method" {
entry:
  %nonempty = icmp sgt i32 %limit, 0
  br i1 %nonempty, label %preheader, label %exit

preheader:
  %wide.limit = zext i32 %limit to i64
  br label %loop

loop:
  %iv = phi i64 [ 0, %preheader ], [ %iv.next, %loop ]
  %sum = phi i64 [ 0, %preheader ], [ %sum.next, %loop ]
  %sum.next = add i64 %sum, %iv
  %iv.next = add nuw nsw i64 %iv, 1
  %local.next = trunc nuw nsw i64 %iv.next to i32
  %local.roundtrip = zext i32 %local.next to i64
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i64 %sum.next, i32 %local.next, i64 %local.roundtrip) ]
  %done = icmp eq i64 %iv.next, %wide.limit
  br i1 %done, label %exit, label %loop

exit:
  %result = phi i64 [ 0, %entry ], [ %sum.next, %loop ]
  ret i64 %result
}

; CHECK-LABEL: @widened_iv_with_i32_deopt(
; CHECK:       loop.outer.latch:
; CHECK:         %local.next.outer = trunc nuw nsw i64 %outer.iv.next to i32
; CHECK-NEXT:    %local.roundtrip.outer = zext i32 %local.next.outer to i64
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}}
; CHECK-SAME:      [ "deopt"(i64 %sum.outer.next, i32 %local.next.outer, i64 %local.roundtrip.outer) ]

; A loop-local cast whose input is invariant is still an inner-loop definition.
; Rebuild it at the outer boundary instead of creating a non-LCSSA use of the
; inner instruction.
define void @cast_of_invariant_is_rebuilt(i64 %limit, i32 %state) "java-method" {
entry:
  %nonempty = icmp sgt i64 %limit, 0
  br i1 %nonempty, label %preheader, label %exit

preheader:
  br label %loop

loop:
  %iv = phi i64 [ 0, %preheader ], [ %iv.next, %loop ]
  %state.wide = zext i32 %state to i64
  %iv.next = add nuw nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i64 %state.wide, i64 %iv.next) ]
  %more = icmp slt i64 %iv.next, %limit
  br i1 %more, label %loop, label %exit

exit:
  ret void
}

; CHECK-LABEL: @cast_of_invariant_is_rebuilt(
; CHECK:       loop.outer.latch:
; CHECK:         %state.wide.outer = zext i32 %state to i64
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}}
; CHECK-SAME:      [ "deopt"(i64 %state.wide.outer, i64 %outer.iv.next) ]

; A self recurrence represents the same invariant local on every iteration.
; Materialize the preheader value directly at the relocated poll.
define void @invariant_self_phi_uses_initial(i64 %limit, ptr %receiver) "java-method" {
entry:
  %nonempty = icmp sgt i64 %limit, 0
  br i1 %nonempty, label %preheader, label %exit

preheader:
  br label %loop

loop:
  %iv = phi i64 [ 0, %preheader ], [ %iv.next, %loop ]
  %this = phi ptr [ %receiver, %preheader ], [ %this, %loop ]
  %iv.next = add nuw nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(ptr %this, i64 %iv.next) ]
  %more = icmp slt i64 %iv.next, %limit
  br i1 %more, label %loop, label %exit

exit:
  ret void
}

; CHECK-LABEL: @invariant_self_phi_uses_initial(
; CHECK:       loop.outer.latch:
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}}
; CHECK-SAME:      [ "deopt"(ptr %receiver, i64 %outer.iv.next) ]

; A cast does not make current-iteration state a batch-boundary value.
define void @cast_of_current_phi_is_rejected(i64 %limit) "java-method" {
entry:
  %nonempty = icmp sgt i64 %limit, 0
  br i1 %nonempty, label %preheader, label %exit

preheader:
  br label %loop

loop:
  %iv = phi i64 [ 0, %preheader ], [ %iv.next, %loop ]
  %local.current = trunc i64 %iv to i32
  %iv.next = add nuw nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 %local.current) ]
  %more = icmp slt i64 %iv.next, %limit
  br i1 %more, label %loop, label %exit

exit:
  ret void
}

; CHECK-LABEL: @cast_of_current_phi_is_rejected(
; CHECK-NOT:   outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %local.current) ]

; A cast of an arbitrary body value is still not reconstructible from the
; outer recurrences.
define void @cast_of_body_value_is_rejected(i64 %limit) "java-method" {
entry:
  %nonempty = icmp sgt i64 %limit, 0
  br i1 %nonempty, label %preheader, label %exit

preheader:
  br label %loop

loop:
  %iv = phi i64 [ 0, %preheader ], [ %iv.next, %loop ]
  %body.value = add i64 %iv, 7
  %local.body = trunc i64 %body.value to i32
  %iv.next = add nuw nsw i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 %local.body) ]
  %more = icmp slt i64 %iv.next, %limit
  br i1 %more, label %loop, label %exit

exit:
  ret void
}

; CHECK-LABEL: @cast_of_body_value_is_rejected(
; CHECK-NOT:   outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %local.body) ]

!java-method-compilation = !{}
