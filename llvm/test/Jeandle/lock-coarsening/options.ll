; RUN: opt -S -passes='lock-coarsening' -jeandle-lock-coarsening=false %s | FileCheck %s --check-prefix=OFF
; RUN: opt -S -passes='lock-coarsening' -jeandle-lock-coarsening=true %s | FileCheck %s --check-prefix=ON

; The pass is controlled by a compiler flag.  Turning it off must be a pure
; no-op, while turning it on must still perform the baseline transformation.


declare void @llvm.lifetime.start.p0(ptr captures(none))
declare void @llvm.lifetime.end.p0(ptr captures(none))

declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind

; OFF-LABEL: define void @chain(
; OFF: %lock0 = alloca i64
; OFF: %lock1 = alloca i64
; OFF: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; OFF: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; OFF: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; OFF: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)

; ON-LABEL: define void @chain(
; ON: %lock0 = alloca i64
; ON-NOT: %lock1 = alloca
; ON: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; ON-NOT: call hotspotcc void @jeandle.monitorexit_with_thin_lock
; ON-NOT: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; ON: store i32 2, ptr addrspace(1) %field
; ON: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
define void @chain(ptr addrspace(1) %obj, ptr addrspace(1) %field) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %field
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  store i32 2, ptr addrspace(1) %field
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret void
}
