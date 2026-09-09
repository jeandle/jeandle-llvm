; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s --check-prefix=CHECK
; RUN: opt -S -verify-each \
; RUN:   -passes="partial-escape-iterative,partial-escape-iterative" \
; RUN:   -jeandle-pea-iterations=8 %s | FileCheck %s --check-prefix=REPEAT
; Case-C identity preparation is monotonic across a loop retry.  Its point-
; local replay still depends on a complete value graph and reaching
; definitions that must survive or roll back with the corresponding effects.
; Each function carries a non-escaping object with a loop-variant field from
; the preheader through the latch. Its first B' differs from the preheader B,
; forcing restoreLoopSnapshot before the cached field PHI converges.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1) nounwind
declare void @sink(ptr addrspace(1))
declare void @use_i32(i32)

; The source fields contain analyzer-owned bitcasts created after the loop
; snapshot. A retry truncates ordinary OwnedInsts, but the surviving replay
; value graph must keep these casts alive until the transform splices them
; before the merged field PHI and its one point-local replay store.
define void @owned_coercion_survives_retry(i1 %choose, i32 %limit)
    gc "hotspotgc" {
entry:
  %carry = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69600 to ptr), i32 16, i1 false)
  %carry.field = getelementptr inbounds i8, ptr addrspace(1) %carry, i64 8
  store atomic i32 0, ptr addrspace(1) %carry.field unordered, align 4
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %next, %latch ]
  store atomic i32 %i, ptr addrspace(1) %carry.field unordered, align 4
  br i1 %choose, label %left, label %right
left:
  %lt = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69601 to ptr), i32 16, i1 false)
  %ltf = getelementptr inbounds i8, ptr addrspace(1) %lt, i64 8
  store atomic i32 1065353216, ptr addrspace(1) %ltf unordered, align 4
  %lv = load atomic float, ptr addrspace(1) %ltf unordered, align 4
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69602 to ptr), i32 16, i1 false) [ "deopt"(i32 696021) ]
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic float %lv, ptr addrspace(1) %af unordered, align 4
  br label %merge
right:
  %rt = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69601 to ptr), i32 16, i1 false)
  %rtf = getelementptr inbounds i8, ptr addrspace(1) %rt, i64 8
  store atomic i32 1073741824, ptr addrspace(1) %rtf unordered, align 4
  %rv = load atomic float, ptr addrspace(1) %rtf unordered, align 4
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69602 to ptr), i32 16, i1 false) [ "deopt"(i32 696022) ]
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic float %rv, ptr addrspace(1) %bf unordered, align 4
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  call void @sink(ptr addrspace(1) %p)
  br label %latch
latch:
  %next = add nuw i32 %i, 1
  %again = icmp ult i32 %next, %limit
  br i1 %again, label %loop, label %exit
exit:
  ret void
}

; CHECK-LABEL: define void @owned_coercion_survives_retry(
; CHECK: left:
; CHECK: %[[LC:pea.coerce[^ ]*]] = bitcast i32 1065353216 to float
; CHECK-NEXT: %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 696021) ]
; CHECK-NOT: store atomic float
; CHECK-NEXT: br label %merge
; CHECK: right:
; CHECK: %[[RC:pea.coerce[^ ]*]] = bitcast i32 1073741824 to float
; CHECK-NEXT: %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 696022) ]
; CHECK-NOT: store atomic float
; CHECK-NEXT: br label %merge
; CHECK: merge:
; CHECK-NEXT: %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
; CHECK-NEXT: %[[CFIELD:pea.casec.field.phi[^ ]*]] = phi float [ %[[LC]], %left ], [ %[[RC]], %right ]
; CHECK-NEXT: %[[CSLOT:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
; CHECK-NEXT: store atomic float %[[CFIELD]], ptr addrspace(1) %[[CSLOT]] unordered, align 4
; CHECK-NEXT: call void @sink(ptr addrspace(1) %p)
; CHECK-NOT: store atomic float
; CHECK-NOT: call void @sink
; CHECK-NOT: poison

; A folded load observes a loop-local field PHI and feeds the fields of two
; sources of the first Case-C identity.  The object producing that field PHI
; later becomes a source of a second Case-C identity through an indirectbr
; edge.  Both identities keep their original source allocations and replay
; their complete current state once onto %p and %qp, respectively.
define void @nested_synthetic_replay_survives_retry(
    i1 %field.choose, i1 %source.choose, i1 %late.choose, ptr %late.target,
    i32 %limit)
    gc "hotspotgc" {
entry:
  %carry = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69600 to ptr), i32 16, i1 false)
  %carry.field = getelementptr inbounds i8, ptr addrspace(1) %carry, i64 8
  store atomic i32 0, ptr addrspace(1) %carry.field unordered, align 4
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %next, %latch ]
  store atomic i32 %i, ptr addrspace(1) %carry.field unordered, align 4
  %q = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69603 to ptr), i32 16, i1 false) [ "deopt"(i32 696031) ]
  %qf = getelementptr inbounds i8, ptr addrspace(1) %q, i64 8
  br i1 %field.choose, label %qleft, label %qright
qleft:
  store atomic i32 7, ptr addrspace(1) %qf unordered, align 4
  br label %qmerge
qright:
  store atomic i32 13, ptr addrspace(1) %qf unordered, align 4
  br label %qmerge
qmerge:
  %field = load atomic i32, ptr addrspace(1) %qf unordered, align 4
  br i1 %source.choose, label %left, label %right
left:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69604 to ptr), i32 16, i1 false) [ "deopt"(i32 696041) ]
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 %field, ptr addrspace(1) %af unordered, align 4
  %av = load atomic i32, ptr addrspace(1) %af unordered, align 4
  br label %merge
right:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69604 to ptr), i32 16, i1 false) [ "deopt"(i32 696042) ]
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 %field, ptr addrspace(1) %bf unordered, align 4
  %bv = load atomic i32, ptr addrspace(1) %bf unordered, align 4
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  %observed = phi i32 [ %av, %left ], [ %bv, %right ]
  call void @sink(ptr addrspace(1) %p)
  br i1 %late.choose, label %qedge, label %redge
qedge:
  indirectbr ptr %late.target, [label %qmerge.identity, label %bypass]
redge:
  %r = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69603 to ptr), i32 16, i1 false) [ "deopt"(i32 696032) ]
  br label %qmerge.identity
qmerge.identity:
  %qp = phi ptr addrspace(1) [ %q, %qedge ], [ %r, %redge ]
  call void @sink(ptr addrspace(1) %qp)
  br label %latch
bypass:
  br label %latch
latch:
  %next = add nuw i32 %i, 1
  %again = icmp ult i32 %next, %limit
  br i1 %again, label %loop, label %exit
exit:
  call void @use_i32(i32 %observed)
  ret void
}

; CHECK-LABEL: define void @nested_synthetic_replay_survives_retry(
; CHECK: %q = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 696031) ]
; CHECK: qleft:
; CHECK-NEXT: br label %qmerge
; CHECK: qright:
; CHECK-NEXT: br label %qmerge
; CHECK: qmerge:
; CHECK-NEXT: %[[QFIELD:pea.field.phi[^ ]*]] = phi i32 [ 13, %qright ], [ 7, %qleft ]
; CHECK: left:
; CHECK-NEXT: %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 696041) ]
; CHECK-NOT: store atomic
; CHECK-NEXT: br label %merge
; CHECK: right:
; CHECK-NEXT: %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 696042) ]
; CHECK-NOT: store atomic
; CHECK-NEXT: br label %merge
; CHECK: merge:
; CHECK-NEXT: %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
; CHECK-NEXT: %[[PSLOT:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
; CHECK-NEXT: store atomic i32 %[[QFIELD]], ptr addrspace(1) %[[PSLOT]] unordered, align 4
; CHECK-NEXT: call void @sink(ptr addrspace(1) %p)
; CHECK: %r = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 696032) ]
; CHECK: qmerge.identity:
; CHECK-NEXT: %qp = phi ptr addrspace(1) [ %q, %qedge ], [ %r, %redge ]
; CHECK-NEXT: %[[QPFIELD:pea.casec.field.phi[^ ]*]] = phi i32 [ %[[QFIELD]], %qedge ], [ 0, %redge ]
; CHECK-NEXT: %[[QPSLOT:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %qp, i64 8
; CHECK-NEXT: store atomic i32 %[[QPFIELD]], ptr addrspace(1) %[[QPSLOT]] unordered, align 4
; CHECK-NEXT: call void @sink(ptr addrspace(1) %qp)
; CHECK-NOT: store atomic i32
; CHECK-NOT: call void @sink
; CHECK: call void @use_i32(i32 %[[QFIELD]])
; CHECK-NOT: poison

; REPEAT-LABEL: define void @owned_coercion_survives_retry(
; REPEAT-NOT: @jeandle.new_instance
; REPEAT: %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; REPEAT-NOT: @jeandle.new_instance
; REPEAT-NOT: store atomic float
; REPEAT: %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; REPEAT-NOT: @jeandle.new_instance
; REPEAT-NOT: store atomic float
; REPEAT: %[[RFIELD:pea.casec.field.phi[^ ]*]] = phi float [ 1.000000e+00, %left ], [ 2.000000e+00, %right ]
; REPEAT-NOT: store atomic float
; REPEAT: store atomic float %[[RFIELD]]
; REPEAT: call void @sink
; REPEAT-NOT: @jeandle.new_instance
; REPEAT-NOT: store atomic float
; REPEAT-NOT: call void @sink
; REPEAT-NOT: poison
; REPEAT-LABEL: define void @nested_synthetic_replay_survives_retry(
; Generic CFG cleanup can prove the indirect source edge dead in this test and
; fold the q diamond to a select.  The selected reaching value must still feed
; the one %p replay and the final use; the surviving %r path gets exactly one
; default-field replay.
; REPEAT: %[[FIELD:[^ ]+]] = select i1 %field.choose, i32 7, i32 13
; REPEAT-NOT: @jeandle.new_instance
; REPEAT: %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; REPEAT-NOT: @jeandle.new_instance
; REPEAT-NOT: store atomic i32
; REPEAT: %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; REPEAT-NOT: @jeandle.new_instance
; REPEAT-NOT: store atomic i32
; REPEAT: %[[RPSLOT:pea.matslot[^ ]*]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %p, i64 8
; REPEAT-NEXT: store atomic i32 %[[FIELD]], ptr addrspace(1) %[[RPSLOT]] unordered, align 4
; REPEAT: call void @sink(ptr addrspace(1) %p)
; REPEAT-NOT: store atomic i32
; REPEAT-NOT: call void @sink
; REPEAT: %r = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; REPEAT-NOT: @jeandle.new_instance
; REPEAT: %[[RQSLOT:pea.matslot[^ ]*]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %r, i64 8
; REPEAT-NEXT: store atomic i32 0, ptr addrspace(1) %[[RQSLOT]] unordered, align 4
; REPEAT-NEXT: call void @sink(ptr addrspace(1) %r)
; REPEAT-NOT: store atomic i32
; REPEAT-NOT: call void @sink
; REPEAT: call void @use_i32(i32 %[[FIELD]])
; REPEAT-NOT: poison

!java-method-compilation = !{}
