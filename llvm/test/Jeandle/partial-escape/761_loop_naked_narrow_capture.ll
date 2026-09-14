; REQUIRES: asserts

; RUN: opt -S \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform,verify" \
; RUN:   %s | FileCheck %s --check-prefix=CHECK
; RUN: opt -S \
; RUN:   -passes="partial-escape-iterative,instcombine,verify" \
; RUN:   %s | FileCheck %s --check-prefix=CLEAN

; A compressed oop loaded directly from heap is a "naked" addrspace(3)
; producer: unlike the usual store boundary it has no AS1 -> AS3 cast whose
; wide operand PEA can reuse.  Such a capture is common for lambda objects
; allocated inside collection loops.  PEA must normalize it to semantic AS1
; state without materializing the otherwise virtual closure.
;
; The semantic cast is analysis-owned. PlaceInstructionEffect parents it at the
; modeled store before the original store is eliminated, and PEAResult owns any
; unparented cast discarded during loop-fixpoint rollback.

target datalayout = "e-p:64:64-p1:64:64-p3:32:32"

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.safepoint_poll()
declare i32 @__gxx_personality_v0(...)

define void @loop_local_naked_narrow_capture(
    ptr addrspace(1) %capture.slot, i32 %limit)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %state = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 75400 to ptr), i32 16, i1 false)
           to label %preheader unwind label %unwind

preheader:
  br label %loop

loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %latch ]
  %captured = load atomic ptr addrspace(3), ptr addrspace(1) %capture.slot
      unordered, align 4
  %closure = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
                 ptr inttoptr (i64 75401 to ptr), i32 24, i1 false)
             to label %init unwind label %unwind

init:
  %state.slot = getelementptr inbounds i8, ptr addrspace(1) %state, i64 8
  store atomic i32 %i, ptr addrspace(1) %state.slot unordered, align 4
  %int.slot = getelementptr inbounds i8, ptr addrspace(1) %closure, i64 12
  store atomic i32 %i, ptr addrspace(1) %int.slot unordered, align 4
  %ref.slot = getelementptr inbounds i8, ptr addrspace(1) %closure, i64 16
  store atomic ptr addrspace(3) %captured, ptr addrspace(1) %ref.slot
      unordered, align 4
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 0, i32 0, i64 12, ptr addrspace(1) %closure) ]
  br label %latch

latch:
  %next = add nuw i32 %i, 1
  %again = icmp ult i32 %next, %limit
  br i1 %again, label %loop, label %exit

exit:
  ret void

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The minimal non-loop form of the same naked AS3 store path. There is no
; explicit AS1 -> AS3 cast on the value operand: PEA must create its semantic
; AS3 -> AS1 view, eliminate the virtual field store, and remove the dead
; allocation.
define void @naked_narrow_oop_field_eliminated(ptr addrspace(3) %v)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
          ptr inttoptr (i64 75402 to ptr), i32 16, i1 false)
       to label %normal unwind label %unwind

normal:
  %f = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic ptr addrspace(3) %v, ptr addrspace(1) %f unordered, align 4
  ret void

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @loop_local_naked_narrow_capture(
; CHECK-NOT: @jeandle.new_instance
; CHECK: %[[WIDE:pea.semantic.oop[^ ]*]] = addrspacecast ptr addrspace(3) %captured to ptr addrspace(1)
; CHECK-NOT: store atomic
; CHECK: call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 0, i32 0,
; CHECK-SAME: i64 {{[0-9]+}}, i64 75401, i32 2,
; CHECK-SAME: i64 51539607562, i32 %i,
; CHECK-SAME: i64 68719476748, ptr addrspace(1) %[[WIDE]],
; CHECK-LABEL: define void @naked_narrow_oop_field_eliminated(
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK: ret void



; CLEAN-LABEL: define void @loop_local_naked_narrow_capture(
; CLEAN-NOT: @jeandle.new_instance
; CLEAN: %[[CLEAN_WIDE:pea.semantic.oop[^ ]*]] = addrspacecast ptr addrspace(3) %captured to ptr addrspace(1)
; CLEAN-NOT: store atomic
; CLEAN: call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 0, i32 0,
; CLEAN-SAME: ptr addrspace(1) %[[CLEAN_WIDE]],
; CLEAN-LABEL: define void @naked_narrow_oop_field_eliminated(
; CLEAN-NOT: @jeandle.new_instance
; CLEAN-NOT: store atomic
; CLEAN: ret void


!java-method-compilation = !{}
