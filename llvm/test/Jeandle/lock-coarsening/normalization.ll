; RUN: opt -S -passes='lock-coarsening' %s | FileCheck %s

; Module tests: the transform must retain exactly one lock slot for an
; adjacent region, move every later exit to that slot, and remove only the
; boundary lifetime markers that described the two old regions.  These checks
; are intentionally IR-shape tests so they remain independent of any particular
; CFG/exception/deopt extension.

declare void @llvm.lifetime.start.p0(ptr captures(none))
declare void @llvm.lifetime.end.p0(ptr captures(none))

declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind

; A three-region chain normalizes two boundaries.  The retained slot is the
; first slot; later exits (and their own lifetime ends) all use it.
;
; CHECK-LABEL: define void @multi_slot_chain(
; CHECK: %slot0 = alloca i64
; CHECK-NOT: %slot1 = alloca
; CHECK-NOT: %slot2 = alloca
; CHECK: call void @llvm.lifetime.start.p0(ptr %slot0)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %slot0)
; CHECK-NOT: call hotspotcc void @jeandle.monitorexit_with_thin_lock
; CHECK-NOT: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK: store i32 1, ptr addrspace(1) %field
; CHECK: store i32 2, ptr addrspace(1) %field
; CHECK: store i32 3, ptr addrspace(1) %field
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %slot0)
; CHECK: call void @llvm.lifetime.end.p0(ptr %slot0)
; CHECK-NOT: call void @llvm.lifetime.start.p0(ptr %slot1)
; CHECK-NOT: call void @llvm.lifetime.end.p0(ptr %slot1)
; CHECK-NOT: call void @llvm.lifetime.start.p0(ptr %slot2)
; CHECK-NOT: call void @llvm.lifetime.end.p0(ptr %slot2)
define void @multi_slot_chain(ptr addrspace(1) %obj, ptr addrspace(1) %field) {
entry:
  %slot0 = alloca i64
  %slot1 = alloca i64
  %slot2 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %slot0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %slot0)
  store i32 1, ptr addrspace(1) %field
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %slot0)
  call void @llvm.lifetime.end.p0(ptr %slot0)
  call void @llvm.lifetime.start.p0(ptr %slot1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %slot1)
  store i32 2, ptr addrspace(1) %field
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %slot1)
  call void @llvm.lifetime.end.p0(ptr %slot1)
  call void @llvm.lifetime.start.p0(ptr %slot2)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %slot2)
  store i32 3, ptr addrspace(1) %field
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %slot2)
  call void @llvm.lifetime.end.p0(ptr %slot2)
  ret void
}

; A pure gap is allowed but must not cause the lifetime range of the retained
; slot to leak into an unrelated later computation.  The gap instruction stays
; in place, and no lifetime marker remains at the old boundary.
;
; CHECK-LABEL: define void @pure_gap_preserves_marker_scope(
; CHECK: %slot0 = alloca i64
; CHECK: %slot1 = alloca i64
; CHECK: call void @llvm.lifetime.start.p0(ptr %slot0)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %slot0)
; CHECK: store i32 1, ptr addrspace(1) %field
; CHECK: %gap = add i32 %input, 1
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %other, ptr %slot1)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %other, ptr %slot1)
; CHECK: call void @llvm.lifetime.end.p0(ptr %slot1)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %slot0)
; CHECK: call void @llvm.lifetime.end.p0(ptr %slot0)
define void @pure_gap_preserves_marker_scope(ptr addrspace(1) %obj,
                                             ptr addrspace(1) %other,
                                             ptr addrspace(1) %field,
                                             i32 %input) {
entry:
  %slot0 = alloca i64
  %slot1 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %slot0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %slot0)
  store i32 1, ptr addrspace(1) %field
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %slot0)
  call void @llvm.lifetime.end.p0(ptr %slot0)
  %gap = add i32 %input, 1
  call void @llvm.lifetime.start.p0(ptr %slot1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %other, ptr %slot1)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %other, ptr %slot1)
  call void @llvm.lifetime.end.p0(ptr %slot1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %slot0)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %slot0)
  call void @llvm.lifetime.end.p0(ptr %slot0)
  ret void
}

; A lifetime marker for an unrelated alloca is not part of the lock-slot
; normalization proof.  Refusing the candidate is safer than silently skipping
; a lifetime edge that a later CFG extension may need to reason about.
;
; CHECK-LABEL: define void @unrelated_lifetime_in_gap(
; CHECK: %slot0 = alloca i64
; CHECK: %slot1 = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %slot0)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %slot0)
; CHECK: call void @llvm.lifetime.end.p0(ptr %unrelated)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %slot1)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %slot1)
define void @unrelated_lifetime_in_gap(ptr addrspace(1) %obj) {
entry:
  %slot0 = alloca i64
  %slot1 = alloca i64
  %unrelated = alloca i64
  call void @llvm.lifetime.start.p0(ptr %slot0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %slot0)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %slot0)
  call void @llvm.lifetime.end.p0(ptr %slot0)
  call void @llvm.lifetime.end.p0(ptr %unrelated)
  call void @llvm.lifetime.start.p0(ptr %slot1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %slot1)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %slot1)
  call void @llvm.lifetime.end.p0(ptr %slot1)
  ret void
}

; The verifier must refuse a candidate whose second slot has a live use outside
; the region.  Keeping the IR unchanged is the only safe outcome.
;
; CHECK-LABEL: define void @second_slot_escapes(
; CHECK: %slot0 = alloca i64
; CHECK: %slot1 = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %slot0)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %slot0)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %slot1)
; CHECK: store i8 1, ptr %slot1
define void @second_slot_escapes(ptr addrspace(1) %obj) {
entry:
  %slot0 = alloca i64
  %slot1 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %slot0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %slot0)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %slot0)
  call void @llvm.lifetime.end.p0(ptr %slot0)
  call void @llvm.lifetime.start.p0(ptr %slot1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %slot1)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %slot1)
  call void @llvm.lifetime.end.p0(ptr %slot1)
  store i8 1, ptr %slot1
  ret void
}
