; RUN: opt -S -passes='lock-coarsening' %s | FileCheck %s

; Real synchronized-method shape after inlining: every monitor enter carries a
; deopt bundle because the method's synthetic lock BCI is a safepoint.  The
; removed enter's bundle dies with the call; the surviving enter keeps its own.
; This is the benchmark regression guard: the pass must not reject a chain just
; because the redundant second acquire is a Java monitor enter with a bundle.

declare void @llvm.lifetime.start.p0(ptr captures(none))
declare void @llvm.lifetime.end.p0(ptr captures(none))

declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind

; CHECK-LABEL: define void @chain_with_deopt_enters(
; CHECK: %lock0 = alloca i64
; CHECK-NOT: %lock{{[1-9]}} = alloca
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0) [ "deopt"(
; CHECK-NOT: call hotspotcc void @jeandle.monitorexit_with_thin_lock
; CHECK-NOT: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK: store i32 1, ptr addrspace(1) %field
; CHECK: store i32 2, ptr addrspace(1) %field
; CHECK: store i32 3, ptr addrspace(1) %field
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: call void @llvm.lifetime.end.p0(ptr %lock0)
define void @chain_with_deopt_enters(ptr addrspace(1) %obj, ptr addrspace(1) %field, i32 %input) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  %lock2 = alloca i64

  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0) [ "deopt"(i64 0, i32 9, i32 9, i64 12, ptr addrspace(1) %obj, ptr %lock0) ]
  store i32 1, ptr addrspace(1) %field
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)

  %gap1 = add i32 %input, 1
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1) [ "deopt"(i64 0, i32 15, i32 15, i64 12, ptr addrspace(1) %obj, ptr %lock1) ]
  store i32 2, ptr addrspace(1) %field
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)

  %gap2 = add i32 %gap1, 1
  call void @llvm.lifetime.start.p0(ptr %lock2)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2) [ "deopt"(i64 0, i32 21, i32 21, i64 12, ptr addrspace(1) %obj, ptr %lock2) ]
  store i32 3, ptr addrspace(1) %field
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
  call void @llvm.lifetime.end.p0(ptr %lock2)
  ret void
}
