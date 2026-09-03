; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @safepoint()
declare void @escape(ptr addrspace(1))
declare void @may_throw()
declare i32 @__gxx_personality_v0(...)

; A value defined after the safepoint in the loop body is legal as a back-edge
; contribution only through SSA PHIs. PEA mirrors that rule for virtual field
; state: the descriptor must use a field PHI in %loop, never %next
; directly.
define void @same_block_loop_field(i32 %limit)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 69101 to ptr), i32 16, i1 false)
       to label %init unwind label %unwind
init:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 1, ptr addrspace(1) %slot unordered, align 4
  br label %loop
loop:
  %i = phi i32 [ 0, %init ], [ %next, %loop ]
  call void @safepoint()
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %o) ]
  %next = add i32 %i, 1
  store atomic i32 %next, ptr addrspace(1) %slot unordered, align 4
  %again = icmp slt i32 %next, %limit
  br i1 %again, label %loop, label %exit
exit:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @same_block_loop_field(
; CHECK: loop:
; CHECK: %[[FIELD:pea\.field\.phi[0-9]*]] = phi i32
; CHECK: call void @safepoint()
; CHECK-SAME: [ "deopt"(
; CHECK-SAME: i64 34359738378, i32 %[[FIELD]]
; CHECK-NOT: i64 34359738378, i32 %next

; A diamond value reaches the loop's early safepoint on the next iteration.
; The diamond field PHI itself does not dominate %early; a loop-header field
; PHI must carry it across the back edge.
define void @diamond_loop_field(i1 %pick, i32 %limit)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 69102 to ptr), i32 16, i1 false)
       to label %init unwind label %unwind
init:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 3, ptr addrspace(1) %slot unordered, align 4
  br label %loop
loop:
  %i = phi i32 [ 0, %init ], [ %next, %merge ]
  call void @safepoint()
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %o) ]
  br i1 %pick, label %left, label %right
left:
  %lv = add i32 %i, 11
  store atomic i32 %lv, ptr addrspace(1) %slot unordered, align 4
  br label %merge
right:
  %rv = add i32 %i, 17
  store atomic i32 %rv, ptr addrspace(1) %slot unordered, align 4
  br label %merge
merge:
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %limit
  br i1 %again, label %loop, label %exit
exit:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @diamond_loop_field(
; CHECK: loop:
; CHECK: %[[HEADER_FIELD:pea\.field\.phi[0-9]*]] = phi i32
; CHECK: call void @safepoint()
; CHECK-SAME: [ "deopt"(
; CHECK-SAME: i64 34359738378, i32 %[[HEADER_FIELD]]
; CHECK-NOT: i64 34359738378, i32 %lv
; CHECK-NOT: i64 34359738378, i32 %rv

; The two inner allocations form a Case-C virtual at %inner.merge. Only that
; path stores it into %outer; %bypass reaches the deopt point without executing
; the merge. Any materialized reference based directly on %inner would
; therefore be unavailable at %join. The descriptor planner must
; either use a join-local field PHI or fall back coherently.
define void @casec_inner_side_entry(i1 %bypass, i1 %pick)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 69103 to ptr), i32 24, i1 false)
           to label %dispatch unwind label %unwind
dispatch:
  %outer.field = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  br i1 %bypass, label %bypass.path, label %choose
choose:
  br i1 %pick, label %left, label %right
left:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 69104 to ptr), i32 16, i1 false)
       to label %inner.merge unwind label %unwind
right:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 69104 to ptr), i32 16, i1 false)
       to label %inner.merge unwind label %unwind
inner.merge:
  %inner = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %outer.field unordered, align 8
  br label %join
bypass.path:
  br label %join
join:
  call void @safepoint()
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %outer) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @casec_inner_side_entry(
; The Case-C value itself does not dominate %join, so the outer field is
; represented by a join-local PHI that does.
; CHECK: join:
; CHECK: %[[JOIN_FIELD:pea\.field\.phi[0-9]*]] = phi ptr addrspace(1) [ null, %bypass.path ], [ %inner, %inner.merge ]
; CHECK: call void @safepoint()
; CHECK-SAME: i64 68719476748, ptr addrspace(1) %[[JOIN_FIELD]]
; CHECK-NOT: poison

; A materialized wide oop is a Scalar descriptor cell. Its original
; allocation dominates the invoke safepoint, including both the normal and
; unwind edges, so the outer object may remain virtual.
define void @available_materialized_oop_invoke(i32 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 69105 to ptr), i32 24, i1 false)
           to label %alloc.inner unwind label %alloc.unwind
alloc.inner:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 69106 to ptr), i32 16, i1 false)
           to label %body unwind label %alloc.unwind
body:
  %outer.value = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
  %outer.ref = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic i32 %value, ptr addrspace(1) %outer.value unordered, align 4
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %outer.ref unordered, align 8
  call void @escape(ptr addrspace(1) %inner)
  invoke void @may_throw()
      [ "deopt"(i32 99, i32 99, i64 12,
                 ptr addrspace(1) %outer) ]
      to label %normal unwind label %handler
normal:
  ret void
handler:
  %lp = landingpad i64 cleanup
  resume i64 %lp
alloc.unwind:
  %alloc.lp = landingpad i64 cleanup
  resume i64 %alloc.lp
}

; CHECK-LABEL: define void @available_materialized_oop_invoke(
; Only the escaped inner allocation survives.
; CHECK-COUNT-1: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: invoke void @may_throw()
; CHECK-SAME: [ "deopt"(
; CHECK-SAME: i64 262156, i64 69105, i32 2,
; CHECK-SAME: i64 34359738378, i32 %value,
; The MaterializedRef is emitted as the available live oop.
; CHECK-SAME: i64 68719476748, ptr addrspace(1) %inner,
; CHECK-SAME: i64 524300, i32 0) ]
; CHECK-NEXT: to label %normal unwind label %handler

; If a transitive child cannot be described, fallback materializes that child
; before the invoke. The outer remains virtual because its reference field can
; then be encoded as the child's available live oop. Both successors inherit
; the child's materialized state and must load from real memory.
define i32 @transitive_fallback_invoke()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 69107 to ptr), i32 24, i1 false)
           to label %alloc.outer unwind label %alloc.unwind
alloc.outer:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
               ptr inttoptr (i64 69108 to ptr), i32 24, i1 false)
           to label %body unwind label %alloc.unwind
body:
  %child.value = getelementptr inbounds i8, ptr addrspace(1) %child, i64 8
  %child.bad = getelementptr inbounds i8, ptr addrspace(1) %child, i64 16
  %outer.ref = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic i32 7, ptr addrspace(1) %child.value unordered, align 4
  store atomic ptr addrspace(1) inttoptr (i64 123 to ptr addrspace(1)),
      ptr addrspace(1) %child.bad unordered, align 8
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %outer.ref unordered, align 8
  invoke void @may_throw()
      [ "deopt"(i32 99, i32 99, i64 12,
                 ptr addrspace(1) %outer) ]
      to label %normal unwind label %handler
normal:
  %normal.value = load atomic i32, ptr addrspace(1) %child.value unordered, align 4
  ret i32 %normal.value
handler:
  %lp = landingpad i64 cleanup
  %handler.value = load atomic i32, ptr addrspace(1) %child.value unordered, align 4
  ret i32 %handler.value
alloc.unwind:
  %alloc.lp = landingpad i64 cleanup
  resume i64 %alloc.lp
}

; CHECK-LABEL: define i32 @transitive_fallback_invoke(
; Only the child allocation survives; the outer allocation is eliminated and
; no materialization allocation is created.
; CHECK-COUNT-1: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: inttoptr (i64 69108 to ptr)
; CHECK-NOT: pea.mat = invoke
; The child's complete state is replayed before the invoke.
; CHECK: %[[CHILD_SLOT8:pea\.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %child, i64 8
; CHECK-NEXT: store atomic i32 7, ptr addrspace(1) %[[CHILD_SLOT8]] unordered, align 4
; CHECK-NEXT: %[[CHILD_SLOT16:pea\.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %child, i64 16
; CHECK-NEXT: store atomic ptr addrspace(1) inttoptr (i64 123 to ptr addrspace(1)), ptr addrspace(1) %[[CHILD_SLOT16]] unordered, align 8
; The virtual outer is described as wire id 0. Its offset-16 field is the
; materialized child oop, and the original outer root becomes VORef wire id 0.
; CHECK-NEXT: invoke void @may_throw()
; CHECK-SAME: [ "deopt"(i32 99, i32 99,
; CHECK-SAME: i64 262156, i64 69108, i32 1,
; CHECK-SAME: i64 68719476748, ptr addrspace(1) %child,
; CHECK-SAME: i64 524300, i32 0) ]
; CHECK-NEXT: to label %normal unwind label %handler
; CHECK: normal:
; CHECK: %normal.value = load atomic i32, ptr addrspace(1) %child.value unordered, align 4
; CHECK: handler:
; CHECK: %handler.value = load atomic i32, ptr addrspace(1) %child.value unordered, align 4
; CHECK-NOT: poison

!java-method-compilation = !{}
