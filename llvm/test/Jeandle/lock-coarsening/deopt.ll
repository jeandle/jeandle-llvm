; RUN: opt -S -passes='lock-coarsening' %s | FileCheck %s --check-prefix=CHECK
; RUN: opt -S -passes='lock-coarsening' %s -jeandle-lock-coarsening=false | FileCheck %s --check-prefix=CHECK-OFF

; Deoptimization bundles in the second region must be rewritten to the retained
; lock slot.  A stale bundle referring to a deleted BasicLock would make the VM
; restore the wrong monitor state.
;
; Deopt bundles in the folded region must be rewritten to the retained slot.

declare void @llvm.lifetime.start.p0(ptr captures(none))
declare void @llvm.lifetime.end.p0(ptr captures(none))

declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @safepoint_like(ptr) nounwind
declare void @sink(ptr)

; CHECK-LABEL: define void @deopt_in_second_region(
; CHECK: %lock0 = alloca i64
; CHECK-NOT: %lock1 = alloca
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: call hotspotcc void @safepoint_like(ptr %lock0) [ "deopt"(i32 99, i32 99, i64 196620, ptr addrspace(1) %obj, ptr %lock0) ]
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
define void @deopt_in_second_region(ptr addrspace(1) %obj) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64

  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)

  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call hotspotcc void @safepoint_like(ptr %lock1) [ "deopt"(i32 99, i32 99, i64 196620, ptr addrspace(1) %obj, ptr %lock1) ]
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret void
}

; CHECK-LABEL: define void @deopt_in_gap(
; CHECK: %lock0 = alloca i64
; CHECK: %lock1 = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: call hotspotcc void @safepoint_like(ptr %lock1) [ "deopt"(i32 99, i32 99, i64 196620, ptr addrspace(1) %obj, ptr %lock1) ]
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
define void @deopt_in_gap(ptr addrspace(1) %obj) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64

  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)

  call hotspotcc void @safepoint_like(ptr %lock1) [ "deopt"(i32 99, i32 99, i64 196620, ptr addrspace(1) %obj, ptr %lock1) ]
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret void
}

; A call without a deopt bundle inside the second region cannot name the
; BasicLock slot in any restorable state, but remains an opaque call.  It must
; not be crossed.
; CHECK-LABEL: define void @opaque_call_inside_second_region(
; CHECK: %lock0 = alloca i64
; CHECK: %lock1 = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; CHECK: call void @sink(ptr %lock1)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
define void @opaque_call_inside_second_region(ptr addrspace(1) %obj) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64

  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)

  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @sink(ptr %lock1)
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret void
}

; A malformed deopt bundle cannot be audited or rewritten safely.  The
; presence of the call must reject the candidate instead of deleting a
; BasicLock that the VM may read at deopt.
; CHECK-LABEL: define void @malformed_deopt_in_second_region(
; CHECK: %lock0 = alloca i64
; CHECK: %lock1 = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; CHECK: call hotspotcc void @safepoint_like(ptr %lock1) [ "deopt"(i32 5, i32 6, i64 12, ptr addrspace(1) %obj) ]
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
define void @malformed_deopt_in_second_region(ptr addrspace(1) %obj) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64

  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)

  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call hotspotcc void @safepoint_like(ptr %lock1) [ "deopt"(i32 5, i32 6, i64 12, ptr addrspace(1) %obj) ]
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret void
}

; CHECK-OFF-LABEL: define void @deopt_in_second_region(
; CHECK-OFF: call hotspotcc void @safepoint_like(ptr %lock1) [ "deopt"(i32 99, i32 99, i64 196620, ptr addrspace(1) %obj, ptr %lock1) ]

; A second monitor record that names an unrelated outer slot must survive
; unchanged.  Only the slot being discarded is rewritten.
; CHECK-LABEL: define void @deopt_with_unrelated_monitor(
; CHECK: %lock0 = alloca i64
; CHECK: %outer = alloca i64
; CHECK: call hotspotcc void @safepoint_like(ptr %lock0) [ "deopt"(i32 99, i32 99, i64 196620, ptr addrspace(1) %obj, ptr %lock0, i64 196620, ptr addrspace(1) %obj, ptr %outer) ]
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
define void @deopt_with_unrelated_monitor(ptr addrspace(1) %obj) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  %outer = alloca i64

  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)

  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call hotspotcc void @safepoint_like(ptr %lock1) [ "deopt"(i32 99, i32 99, i64 196620, ptr addrspace(1) %obj, ptr %lock1, i64 196620, ptr addrspace(1) %obj, ptr %outer) ]
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret void
}

; A well-formed deopt bundle that does not name the discarded slot is safe to
; cross: RAUW preserves the bundle's unrelated values.
; CHECK-LABEL: define void @deopt_without_lock_slot(
; CHECK: %lock0 = alloca i64
; CHECK-NOT: %lock1 = alloca
; CHECK: call hotspotcc void @safepoint_like(ptr %lock0) [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %obj) ]
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
define void @deopt_without_lock_slot(ptr addrspace(1) %obj) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call hotspotcc void @safepoint_like(ptr %lock1) [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %obj) ]
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret void
}

; A monitor record whose lock cell names the discarded slot but whose owner is
; another object is malformed for this region.  It must reject the candidate.
; CHECK-LABEL: define void @deopt_monitor_owner_mismatch(
; CHECK: %lock0 = alloca i64
; CHECK: %lock1 = alloca i64
; CHECK: call hotspotcc void @safepoint_like(ptr %lock1) [ "deopt"(i32 99, i32 99, i64 196620, ptr addrspace(1) %other, ptr %lock1) ]
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
define void @deopt_monitor_owner_mismatch(ptr addrspace(1) %obj, ptr addrspace(1) %other) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call hotspotcc void @safepoint_like(ptr %lock1) [ "deopt"(i32 99, i32 99, i64 196620, ptr addrspace(1) %other, ptr %lock1) ]
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret void
}

; The second monitor exit itself may carry a deopt point.  Its lock record must
; be rewritten together with the exit's lock argument.
; CHECK-LABEL: define void @deopt_on_second_exit(
; CHECK: %lock0 = alloca i64
; CHECK-NOT: %lock1 = alloca
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0) [ "deopt"(i32 99, i32 99, i64 196620, ptr addrspace(1) %obj, ptr %lock0) ]
define void @deopt_on_second_exit(ptr addrspace(1) %obj) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1) [ "deopt"(i32 99, i32 99, i64 196620, ptr addrspace(1) %obj, ptr %lock1) ]
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret void
}

; A BasicLock slot is only legal in a monitor-lock cell.  If the same value
; appears in an unrelated deopt cell, rewriting it would change semantics, so
; the candidate must be rejected.
; CHECK-LABEL: define void @deopt_non_monitor_lock_cell(
; CHECK: %lock0 = alloca i64
; CHECK: %lock1 = alloca i64
; CHECK: call hotspotcc void @safepoint_like(ptr %lock1) [ "deopt"(i32 99, i32 99, i64 12, ptr %lock1) ]
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
define void @deopt_non_monitor_lock_cell(ptr addrspace(1) %obj) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call hotspotcc void @safepoint_like(ptr %lock1) [ "deopt"(i32 99, i32 99, i64 12, ptr %lock1) ]
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret void
}
