; RUN: opt -S -passes='lock-coarsening' %s | FileCheck %s
; RUN: opt -S -passes='lock-coarsening' %s | grep -c 'call hotspotcc void @jeandle.monitorenter_with_thin_lock' | FileCheck %s --check-prefix=ENTER-COUNT
; RUN: opt -S -passes='lock-coarsening' %s | grep -c 'call hotspotcc void @jeandle.monitorexit_with_thin_lock' | FileCheck %s --check-prefix=EXIT-COUNT

; Nested reentrant regions on the same object.  The final optimization must
; fold the redundant inner acquisitions into the outer one while preserving
; the outer critical section.  This is the nested_synchronized benchmark shape.
;
; ENTER-COUNT: 1
; EXIT-COUNT: 1

declare void @llvm.lifetime.start.p0(ptr captures(none))
declare void @llvm.lifetime.end.p0(ptr captures(none))

declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind

; CHECK-LABEL: define void @nested_same_object(
; CHECK: %lock0 = alloca i64
; CHECK-NOT: %lock{{[1-9]}} = alloca
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK-NOT: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK-NOT: call hotspotcc void @jeandle.monitorexit_with_thin_lock
; CHECK: store i32 1, ptr addrspace(1) %field
; CHECK: store i32 8, ptr addrspace(1) %field
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
define void @nested_same_object(ptr addrspace(1) %obj, ptr addrspace(1) %field) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  %lock2 = alloca i64
  %lock3 = alloca i64
  %lock4 = alloca i64
  %lock5 = alloca i64
  %lock6 = alloca i64
  %lock7 = alloca i64

  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %field

  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  store i32 2, ptr addrspace(1) %field

  call void @llvm.lifetime.start.p0(ptr %lock2)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
  store i32 3, ptr addrspace(1) %field

  call void @llvm.lifetime.start.p0(ptr %lock3)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock3)
  store i32 4, ptr addrspace(1) %field

  call void @llvm.lifetime.start.p0(ptr %lock4)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock4)
  store i32 5, ptr addrspace(1) %field

  call void @llvm.lifetime.start.p0(ptr %lock5)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock5)
  store i32 6, ptr addrspace(1) %field

  call void @llvm.lifetime.start.p0(ptr %lock6)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock6)
  store i32 7, ptr addrspace(1) %field

  call void @llvm.lifetime.start.p0(ptr %lock7)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock7)
  store i32 8, ptr addrspace(1) %field

  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock7)
  call void @llvm.lifetime.end.p0(ptr %lock7)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock6)
  call void @llvm.lifetime.end.p0(ptr %lock6)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock5)
  call void @llvm.lifetime.end.p0(ptr %lock5)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock4)
  call void @llvm.lifetime.end.p0(ptr %lock4)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock3)
  call void @llvm.lifetime.end.p0(ptr %lock3)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
  call void @llvm.lifetime.end.p0(ptr %lock2)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  ret void
}
