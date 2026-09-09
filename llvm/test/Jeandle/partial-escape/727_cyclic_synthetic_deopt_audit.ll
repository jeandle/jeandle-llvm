; RUN: opt -S -verify-each \
; RUN:   -passes="loop-simplify,require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/231_value_based_check_value_based.cblog \
; RUN:   %s | FileCheck %s

; Loop-header and latch Case C merges form a cyclic synthetic-source graph.
; The equality replacement is later dropped when %guard is rejected by the
; value-based check, so the final deopt audit must walk through %pnext.  The
; walk must terminate on a visited ObjectID set, find both ordinary loop
; allocation leaves, and retry with those sites retained as real objects.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1
    @jeandle.check_if_value_based(ptr addrspace(1))
declare void @safepoint()
declare void @observe(i1)
declare i32 @__gxx_personality_v0(...)

define void @cyclic_synthetic_deopt_audit(i32 %n)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %guard = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
      to label %alloc.initial unwind label %unwind

alloc.initial:
  %initial = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
      to label %preheader unwind label %unwind

preheader:
  br label %loop

loop:
  %i = phi i32 [ 0, %preheader ], [ %next.i, %latch ]
  %carried = phi ptr addrspace(1)
      [ %initial, %preheader ], [ %next.object, %latch ]
  %replace = icmp eq i32 %i, 3
  br i1 %replace, label %allocate.replacement, label %keep

allocate.replacement:
  %replacement = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
      to label %replacement.normal unwind label %unwind

replacement.normal:
  br label %latch

keep:
  br label %latch

latch:
  %next.object = phi ptr addrspace(1)
      [ %replacement, %replacement.normal ], [ %carried, %keep ]
  %next.i = add i32 %i, 1
  %continue = icmp slt i32 %next.i, %n
  br i1 %continue, label %loop, label %exit

exit:
  %same = icmp eq ptr addrspace(1) %guard, %next.object
  call void @safepoint()
      [ "deopt"(i32 99, i32 99, i64 10, i1 %same) ]
  %is.value.based = call hotspotcc i1
      @jeandle.check_if_value_based(ptr addrspace(1) %guard)
  call void @observe(i1 %is.value.based)
  ret void

unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @cyclic_synthetic_deopt_audit(
; CHECK-COUNT-3: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %same = icmp eq ptr addrspace(1) %guard, %next.object
; CHECK: call void @safepoint()
; CHECK-SAME: i1 %same
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based(
; CHECK-NOT: poison

!java-method-compilation = !{}
