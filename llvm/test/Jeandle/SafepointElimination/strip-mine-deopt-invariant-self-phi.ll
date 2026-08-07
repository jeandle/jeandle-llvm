; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal \
; RUN:   -S < %s | FileCheck %s
; RUN: opt -passes='function(loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>),java-operation-lower<phase=1>,rewrite-statepoints-for-gc,verify' \
; RUN:   -S < %s | FileCheck %s --check-prefix=STATEPOINT

; A frontend can represent an unchanged local such as `this` with a header phi
; whose latch value is the phi itself. Loop canonicalization removes that
; redundant recurrence, and strip mining passes the invariant receiver directly
; to the relocated poll.

declare hotspotcc void @safepoint_handler()

define private hotspotcc void @jeandle.safepoint_poll() #0 {
entry:
  call hotspotcc void @safepoint_handler() [ "deopt"() ]
  ret void
}

define void @invariant_self_phi(i64 %n, ptr addrspace(1) %receiver) "java-method" gc "hotspotgc" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %this = phi ptr addrspace(1) [ %receiver, %entry ], [ %this, %latch ]
  %cond = icmp slt i64 %iv, %n
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(ptr addrspace(1) %this, i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

!java-method-compilation = !{}

attributes #0 = { "lower-phase"="1" "noinline" }

; CHECK-LABEL: @invariant_self_phi(
; CHECK:       body:
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll
; CHECK:       body.outer.latch:
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}} [ "deopt"(ptr addrspace(1) %receiver, i64 %outer.iv.next) ]

; STATEPOINT-LABEL: @invariant_self_phi(
; STATEPOINT:       body.outer:
; STATEPOINT:         %[[THIS:[^ ]+]] = phi ptr addrspace(1) [ %receiver, %body.outer.ph ], [ %[[RELOCATED:[^, ]+]], %body.outer.latch ]
; STATEPOINT:       body.outer.latch:
; STATEPOINT:         %[[TOKEN:[^ ]+]] = call hotspotcc token {{.*}}@llvm.experimental.gc.statepoint.p0(
; STATEPOINT-SAME:      ptr elementtype(void ()) @safepoint_handler
; STATEPOINT-SAME:      [ "deopt"(ptr addrspace(1) %[[THIS]], i64 %iv.next), "gc-live"(ptr addrspace(1) %[[THIS]]) ]
; STATEPOINT-NEXT:    %[[RELOCATED]] = call coldcc ptr addrspace(1) @llvm.experimental.gc.relocate.p1(token %[[TOKEN]], i32 0, i32 0)
