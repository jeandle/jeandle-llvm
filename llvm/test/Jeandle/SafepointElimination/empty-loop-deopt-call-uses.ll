; RUN: opt -verify-each \
; RUN:   -passes='function(safepoint-poll-elimination<loop-deletion-prep>,verify<jeandle-safepoint-coverage>)' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -S < %s \
; RUN:   | FileCheck %s

declare hotspotcc void @jeandle.safepoint_poll()
declare hotspotcc void @guaranteed_safepoint()
declare hotspotcc void @not_guaranteed_safepoint() #0
declare hotspotcc void @semantic_user(i32)

attributes #0 = { "jeandle.not-guaranteed-safepoint" }

; A loop exit value used only by a guaranteed safepoint call's deopt bundle is
; debug state. Materialize the value before the loop and delete the loop.
define void @delete_when_liveout_reaches_guaranteed_call(i32 %n) "java-method" {
entry:
  %positive = icmp sgt i32 %n, 0
  br i1 %positive, label %preheader, label %exit.zero

preheader:
  br label %loop

loop:
  %iv = phi i32 [ 0, %preheader ], [ %iv.next, %loop ]
  %iv.next = add nuw nsw i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %continue = icmp slt i32 %iv.next, %n
  br i1 %continue, label %loop, label %loop.exit

loop.exit:
  %final.loop = phi i32 [ %iv.next, %loop ]
  br label %exit

exit.zero:
  br label %exit

exit:
  %final = phi i32 [ 0, %exit.zero ], [ %final.loop, %loop.exit ]
  call hotspotcc void @guaranteed_safepoint() [ "deopt"(i32 %final) ]
  ret void
}

; CHECK-LABEL: @delete_when_liveout_reaches_guaranteed_call(
; CHECK-NOT:   loop:
; CHECK-NOT:   call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       call hotspotcc void @guaranteed_safepoint() [ "deopt"(i32 %final) ]

; A NotGuaranteedSafepoint call carries deopt state but does not satisfy the
; isSafepoint contract. Conservatively retain the loop.
define void @keep_when_liveout_reaches_non_safepoint_call(i32 %n) "java-method" {
entry:
  %positive = icmp sgt i32 %n, 0
  br i1 %positive, label %preheader, label %exit.zero
preheader:
  br label %loop
loop:
  %iv = phi i32 [ 0, %preheader ], [ %iv.next, %loop ]
  %iv.next = add nuw nsw i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %continue = icmp slt i32 %iv.next, %n
  br i1 %continue, label %loop, label %loop.exit
loop.exit:
  %final.loop = phi i32 [ %iv.next, %loop ]
  br label %exit
exit.zero:
  br label %exit
exit:
  %final = phi i32 [ 0, %exit.zero ], [ %final.loop, %loop.exit ]
  call hotspotcc void @not_guaranteed_safepoint() [ "deopt"(i32 %final) ]
  ret void
}

; CHECK-LABEL: @keep_when_liveout_reaches_non_safepoint_call(
; CHECK:       loop:
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       call hotspotcc void @not_guaranteed_safepoint()

; Even at a guaranteed safepoint, an ordinary argument is a semantic use. The
; exact Use must be checked instead of accepting every use by the CallBase.
define void @keep_when_liveout_is_regular_call_argument(i32 %n) "java-method" {
entry:
  %positive = icmp sgt i32 %n, 0
  br i1 %positive, label %preheader, label %exit.zero
preheader:
  br label %loop
loop:
  %iv = phi i32 [ 0, %preheader ], [ %iv.next, %loop ]
  %iv.next = add nuw nsw i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %continue = icmp slt i32 %iv.next, %n
  br i1 %continue, label %loop, label %loop.exit
loop.exit:
  %final.loop = phi i32 [ %iv.next, %loop ]
  br label %exit
exit.zero:
  br label %exit
exit:
  %final = phi i32 [ 0, %exit.zero ], [ %final.loop, %loop.exit ]
  call hotspotcc void @semantic_user(i32 %final) [ "deopt"(i32 %final) ]
  ret void
}

; CHECK-LABEL: @keep_when_liveout_is_regular_call_argument(
; CHECK:       loop:
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       call hotspotcc void @semantic_user(i32 %final)

!java-method-compilation = !{}
