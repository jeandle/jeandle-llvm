; RUN: opt -S -verify-each -passes=partial-escape-iterative \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/745_loop_seeded_materialization.cblog \
; RUN:   %s | FileCheck %s
; RUN: opt -disable-output -verify-each -passes=partial-escape-iterative \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/745_loop_seeded_materialization.cblog \
; RUN:   -jeandle-trace-pea %s 2>&1 | FileCheck %s --check-prefix=TRACE

; A materialization discovered while converging an inner loop seeds the outer
; retry.  The outer retry must start from its prior merged header state while
; processing inner loops from fresh edge states for that round, without
; retaining replay effects emitted by the earlier traversal.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.safepoint_poll()
declare void @use(i32)

define ptr addrspace(1) @loop_seeded_materialization(i1 %first.done,
                                                      i1 %second.done)
    gc "hotspotgc" personality ptr null {
entry:
  %object = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74501 to ptr), i32 0, i1 false)
  store i8 0, ptr addrspace(1) %object, align 1
  br label %outer.preheader

outer.preheader:
  br label %outer.header

outer.header:
  br label %inner.first.header

inner.first.header:
  br i1 %first.done, label %between.inners, label %inner.first.safepoint

inner.first.safepoint:
  invoke hotspotcc void @jeandle.safepoint_poll()
      to label %inner.first.header unwind label %unwind.first

unwind.first:
  %first.exception = landingpad i64 cleanup
  ret ptr addrspace(1) null

between.inners:
  br label %inner.second.header

inner.second.header:
  br i1 %second.done, label %late, label %inner.second.safepoint

inner.second.safepoint:
  invoke hotspotcc void @jeandle.safepoint_poll()
      to label %inner.second.header unwind label %unwind.second

unwind.second:
  %second.exception = landingpad i64 cleanup
  ret ptr addrspace(1) null

late:
  store i32 0, ptr addrspace(1) %object, align 4
  br label %outer.header
}

; The post-body merge changes B from field value 0 to a loop-carried field
; PHI.  The next traversal must consume that B directly: its load precedes the
; store of the next iteration's value and therefore folds to the field PHI,
; not back to the preheader's constant 0.
define void @loop_seeded_field_value(i1 %done)
    gc "hotspotgc" personality ptr null {
entry:
  %object = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74501 to ptr), i32 16, i1 false)
  %entry.field = getelementptr i8, ptr addrspace(1) %object, i64 8
  store atomic i32 0, ptr addrspace(1) %entry.field unordered, align 4
  br label %loop.preheader

loop.preheader:
  br label %loop.header

loop.header:
  %field = getelementptr i8, ptr addrspace(1) %object, i64 8
  %current = load atomic i32, ptr addrspace(1) %field unordered, align 4
  call void @use(i32 %current)
  store atomic i32 1, ptr addrspace(1) %field unordered, align 4
  br i1 %done, label %exit, label %loop.latch

loop.latch:
  br label %loop.header

exit:
  ret void
}

; The seeded field is replayed once on the outer forward edge.
; CHECK-LABEL: define ptr addrspace(1) @loop_seeded_materialization(
; CHECK: entry:
; CHECK: [[OBJECT:%.*]] = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NEXT: store atomic i8 0, ptr addrspace(1) [[OBJECT]] unordered, align 1
; CHECK-NOT: .pea.replay:
; CHECK: }

; CHECK-LABEL: define void @loop_seeded_field_value(
; CHECK-NOT: jeandle.new_instance
; CHECK: [[FIELD:%pea.field.phi[^ ]*]] = phi i32
; CHECK: call void @use(i32 [[FIELD]])
; CHECK-NOT: load atomic
; CHECK-NOT: store atomic
; CHECK: ret void

; TRACE-LABEL: PEA: EliminateAllocation function=@loop_seeded_materialization [VO=0]{{.*}}ptr nonnull
; TRACE: PEA: Materialize function=@loop_seeded_materialization [VO=0] block=%entry
; TRACE-NOT: PEA: Materialize function=@loop_seeded_materialization [VO=0]

!java-method-compilation = !{}
