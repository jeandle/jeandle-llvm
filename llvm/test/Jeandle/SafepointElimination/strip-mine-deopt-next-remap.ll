; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s
; RUN: opt -passes='function(loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>),java-operation-lower<phase=1>,rewrite-statepoints-for-gc,verify' \
; RUN:   -S < %s | FileCheck %s --check-prefix=STATEPOINT \
; RUN:   --implicit-check-not='call hotspotcc void @jeandle.safepoint_poll'

; Real-frontend-shaped deopt bundle at a back-edge poll: an interleaved list of
; bci + encode constants (loop-invariant, pass through) and the loop-carried
; "next" values %s.next / %iv.next (the state to resume the next iteration, NOT
; the header phis). The increment is computed in the body before the poll, as
; the frontend emits it. Strip mining must remap the .next operands to the outer
; batch-boundary recurrences and leave the invariants alone -- not decline.

declare hotspotcc void @safepoint_handler()

; Phase-1 lowering inlines the poll JavaOp and transfers the call site's deopt
; bundle to its safepoint-capable runtime call.
define private hotspotcc void @jeandle.safepoint_poll() #0 {
entry:
  call hotspotcc void @safepoint_handler() [ "deopt"() ]
  ret void
}

define i64 @sum(i64 noundef %n, ptr addrspace(1) %obj) "java-method" gc "hotspotgc" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %s  = phi i64 [ 0, %entry ], [ %s.next, %latch ]
  %cond = icmp slt i64 %iv, %n
  br i1 %cond, label %body, label %exit

body:
  %s.next = add i64 %s, %iv
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 23, ptr addrspace(1) %obj, i64 %n, i64 8589934603, i64 %s.next, i64 17179869195, i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  %s.lcssa = phi i64 [ %s, %header ]
  ret i64 %s.lcssa
}

!java-method-compilation = !{}

attributes #0 = { "lower-phase"="1" "noinline" }

; Inner body poll-free; poll relocates to the outer latch with invariants passed
; through and .next operands remapped (%s.next -> %s.outer.next,
; %iv.next -> %outer.iv.next).
; CHECK-LABEL: @sum(
; CHECK:       body:
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll
; CHECK:       latch:
; CHECK:         icmp slt i64 %iv.next, %outer.inner.limit
; CHECK:       body.outer.latch:
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}} [ "deopt"(i32 23, ptr addrspace(1) %obj, i64 %n, i64 8589934603, i64 %s3.outer.next, i64 17179869195, i64 %outer.iv.next) ]

; STATEPOINT-LABEL: @sum(
; STATEPOINT:       body:
; STATEPOINT:         %[[SUM:[^ ]+]] = phi i64
; STATEPOINT:         %[[IV:[^ ]+]] = phi i64
; STATEPOINT:         %[[SUM_NEXT:[^ ]+]] = add i64 %[[SUM]], %[[IV]]
; STATEPOINT:         %[[IV_NEXT:[^ ]+]] = add i64 %[[IV]], 1
; STATEPOINT:       body.outer:
; STATEPOINT:         %[[OBJ:[^ ]+]] = phi ptr addrspace(1) [ %obj, %body.outer.ph ], [ %[[RELOCATED:[^, ]+]], %body.outer.latch ]
; STATEPOINT:       body.outer.latch:
; STATEPOINT:         %[[TOKEN:[^ ]+]] = call hotspotcc token {{.*}}@llvm.experimental.gc.statepoint.p0(
; STATEPOINT-SAME:      ptr elementtype(void ()) @safepoint_handler
; STATEPOINT-SAME:      [ "deopt"(i32 23, ptr addrspace(1) %[[OBJ]], i64 %n, i64 8589934603, i64 %[[SUM_NEXT]], i64 17179869195, i64 %[[IV_NEXT]]), "gc-live"(ptr addrspace(1) %[[OBJ]]) ]
; STATEPOINT-NEXT:    %[[RELOCATED]] = call coldcc ptr addrspace(1) @llvm.experimental.gc.relocate.p1(token %[[TOKEN]], i32 0, i32 0)
