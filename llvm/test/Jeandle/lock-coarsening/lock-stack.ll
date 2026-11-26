; RUN: opt -S -passes='lock-coarsening' %s | FileCheck %s

; The lock stack keeps a known top-of-stack suffix across CFG joins.  These
; tests pin the boundary of that proof: a common suffix survives a join, but
; an unknown outer region must not be mistaken for an empty stack.

declare void @llvm.lifetime.start.p0(ptr captures(none))
declare void @llvm.lifetime.end.p0(ptr captures(none))

declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))

; The outer monitor is live on both incoming paths, so the join retains it as
; the known suffix and the following adjacent regions can still be coarsened.
; CHECK-LABEL: define void @join_preserves_known_outer(
; CHECK: %lock0 = alloca i64
; CHECK-NOT: %lock{{[1-9]}} = alloca
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: outer:
; CHECK: br i1 %p, label %left, label %right
; CHECK: left:
; CHECK: br label %merge
; CHECK: right:
; CHECK: br label %merge
; CHECK: merge:
; CHECK-NOT: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK: store i32 1, ptr addrspace(1) %aq
; CHECK: store i32 2, ptr addrspace(1) %aq
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
define void @join_preserves_known_outer(ptr addrspace(1) %obj, ptr addrspace(1) %aq, i1 %p) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  %lock2 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  br label %outer

outer:
  br i1 %p, label %left, label %right

left:
  br label %merge

right:
  br label %merge

merge:
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  store i32 1, ptr addrspace(1) %aq
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  call void @llvm.lifetime.start.p0(ptr %lock2)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
  store i32 2, ptr addrspace(1) %aq
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
  call void @llvm.lifetime.end.p0(ptr %lock2)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  ret void
}

; An OSR root may enter with interpreter-held monitors.  The stack represents
; that prefix as unknown-outer, which must not poison the local top suffix:
; adjacent regions above it are still analyzable and mergeable.
; CHECK-LABEL: define void @__jeandle_osr_unknown_outer_local_suffix(
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK-NOT: %lock2 = alloca
; CHECK: call void @llvm.lifetime.start.p0(ptr %lock1)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; CHECK-NOT: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK: store i32 1, ptr addrspace(1) %obj
; CHECK: store i32 2, ptr addrspace(1) %obj
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; CHECK: ret void
define void @__jeandle_osr_unknown_outer_local_suffix(ptr addrspace(1) %obj) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  %lock2 = alloca i64
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  call void @llvm.lifetime.start.p0(ptr %lock2)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
  call void @llvm.lifetime.end.p0(ptr %lock2)
  ret void
}

; A mismatched release must invalidate the local stack rather than pop an
; unrelated outer frame.
; CHECK-LABEL: define void @mismatched_release_breaks_stack(
; CHECK: %lock0 = alloca i64
; CHECK: %lock1 = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
define void @mismatched_release_breaks_stack(ptr addrspace(1) %obj) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  ret void
}
