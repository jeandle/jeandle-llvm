; RUN: opt -S -passes='lock-coarsening' %s | FileCheck %s

; Permanent guardrails: these shapes must never be merged by the final design.
; They are independent of the current conservative implementation and are
; must remain rejected.

declare void @llvm.lifetime.start.p0(ptr captures(none))
declare void @llvm.lifetime.end.p0(ptr captures(none))

declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare hotspotcc void @safepoint_like(ptr) nounwind

; CHECK-LABEL: define void @partial_conditional(
; CHECK: %lock0 = alloca i64
; CHECK: %lock1 = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
define void @partial_conditional(ptr addrspace(1) %obj, i1 %p) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  br i1 %p, label %then, label %done
then:
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  br label %done
done:
  ret void
}

; CHECK-LABEL: define void @unknown_call_in_gap(
; CHECK: %lock0 = alloca i64
; CHECK: %lock1 = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: call void @sink(ptr addrspace(1) %obj)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
define void @unknown_call_in_gap(ptr addrspace(1) %obj) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  call void @sink(ptr addrspace(1) %obj)
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret void
}

; CHECK-LABEL: define void @unknown_call_inside_second_region(
; CHECK: %lock0 = alloca i64
; CHECK: %lock1 = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; CHECK: call void @sink(ptr addrspace(1) %obj)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
define void @unknown_call_inside_second_region(ptr addrspace(1) %obj) {
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
  call void @sink(ptr addrspace(1) %obj)
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret void
}

; CHECK-LABEL: define void @safepoint_in_gap(
; CHECK: %lock0 = alloca i64
; CHECK: %lock1 = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: call hotspotcc void @safepoint_like(ptr %lock0) [ "deopt"(i64 0) ]
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
define void @safepoint_in_gap(ptr addrspace(1) %obj) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  call hotspotcc void @safepoint_like(ptr %lock0) [ "deopt"(i64 0) ]
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret void
}

; CHECK-LABEL: define void @different_object_nested(
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %a, ptr %lock0)
; CHECK-NEXT: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %b, ptr %lock1)
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %b, ptr %lock1)
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %a, ptr %lock0)
define void @different_object_nested(ptr addrspace(1) %a, ptr addrspace(1) %b) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %a, ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %b, ptr %lock1)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %b, ptr %lock1)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %a, ptr %lock0)
  ret void
}

; CHECK-LABEL: define void @unbalanced_missing_exit(
; CHECK: %lock0 = alloca i64
; CHECK: %lock1 = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; CHECK-NOT: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
define void @unbalanced_missing_exit(ptr addrspace(1) %obj) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  unreachable
}

; CHECK-LABEL: define void @volatile_in_gap(
; CHECK: %lock0 = alloca i64
; CHECK: %lock1 = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: store atomic volatile i32 7, ptr addrspace(1) %obj seq_cst, align 4
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
define void @volatile_in_gap(ptr addrspace(1) %obj) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  store atomic volatile i32 7, ptr addrspace(1) %obj seq_cst, align 4
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret void
}
