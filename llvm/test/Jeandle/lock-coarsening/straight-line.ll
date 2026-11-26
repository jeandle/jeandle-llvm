; RUN: opt -S -passes='lock-coarsening' %s | FileCheck %s

declare void @llvm.lifetime.start.p0(ptr captures(none))
declare void @llvm.lifetime.end.p0(ptr captures(none))

declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @statepoint_like(ptr) nounwind

; CHECK-LABEL: define void @chain(
; CHECK: %lock0 = alloca i64
; CHECK-NOT: %lock1 = alloca
; CHECK: call void @llvm.lifetime.start.p0(ptr %lock0)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK-NOT: call hotspotcc void @jeandle.monitorexit_with_thin_lock
; CHECK-NOT: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK: store i32 2, ptr addrspace(1) %field
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: call void @llvm.lifetime.end.p0(ptr %lock0)
define void @chain(ptr addrspace(1) %obj, ptr addrspace(1) %field, i32 %input) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %field
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  %pure.gap = add i32 %input, 1
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  store i32 2, ptr addrspace(1) %field
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret void
}

; CHECK-LABEL: define void @different_object(
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %a, ptr %lock0)
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %a, ptr %lock0)
; CHECK-NEXT: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %b, ptr %lock1)
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %b, ptr %lock1)
define void @different_object(ptr addrspace(1) %a, ptr addrspace(1) %b) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %a, ptr %lock0)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %a, ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %b, ptr %lock1)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %b, ptr %lock1)
  ret void
}

; CHECK-LABEL: define void @safepoint_in_second_region(
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK-NEXT: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; CHECK-NEXT: call hotspotcc void @statepoint_like(ptr %lock1)
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
define void @safepoint_in_second_region(ptr addrspace(1) %obj) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call hotspotcc void @statepoint_like(ptr %lock1) [ "deopt"(i64 0) ]
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  ret void
}

; CHECK-LABEL: define void @different_mode(
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock
define void @different_mode(ptr addrspace(1) %obj) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %obj, ptr %lock1)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %obj, ptr %lock1)
  ret void
}
