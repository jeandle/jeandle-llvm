; RUN: opt -S -passes='lock-coarsening' %s | FileCheck %s
; RUN: opt -S -passes='lock-coarsening' %s | grep -c 'call hotspotcc void @jeandle.monitorenter_with_thin_lock' | FileCheck %s --check-prefix=ENTER-COUNT
; RUN: opt -S -passes='lock-coarsening' %s | grep -c 'call hotspotcc void @jeandle.monitorexit_with_thin_lock' | FileCheck %s --check-prefix=EXIT-COUNT

; A fully covered conditional may have multiple exits on separate
; return paths.  The retained outer enter must dominate every path, and each
; path must release the monitor before returning.
;
; ENTER-COUNT: 3
; EXIT-COUNT: 4

declare void @llvm.lifetime.start.p0(ptr captures(none))
declare void @llvm.lifetime.end.p0(ptr captures(none))
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind

; Two early returns: every path is protected by the outer lock and releases it
; immediately before returning.  All three monitor regions fold into lock0.
; CHECK-LABEL: define void @early_return_all_paths_covered(
; CHECK: %lock0 = alloca i64
; CHECK-NOT: %lock{{[1-9]}} = alloca
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK-NOT: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK-NOT: call hotspotcc void @jeandle.monitorexit_with_thin_lock
; CHECK: br i1 %p, label %left, label %right
; CHECK: left:
; CHECK: store i32 1, ptr addrspace(1) %obj
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: ret void
; CHECK: right:
; CHECK: store i32 2, ptr addrspace(1) %obj
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: ret void
define void @early_return_all_paths_covered(ptr addrspace(1) %obj, i1 %p) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  %lock2 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 0, ptr addrspace(1) %obj
  br i1 %p, label %left, label %right

left:
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  ret void

right:
  call void @llvm.lifetime.start.p0(ptr %lock2)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
  call void @llvm.lifetime.end.p0(ptr %lock2)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  ret void
}

; If one early-return path is not covered by the outer monitor, no path may
; be rewritten; otherwise that return would release a monitor it never
; acquired or leak the retained lock.
; CHECK-LABEL: define void @early_return_missing_arm_exit(
; CHECK: %lock0 = alloca i64
; CHECK: %lock1 = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: br i1 %p, label %covered, label %uncovered
; CHECK: covered:
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; CHECK: ret void
; CHECK: uncovered:
; CHECK-NOT: call hotspotcc void @jeandle.monitorexit_with_thin_lock
; CHECK: ret void
define void @early_return_missing_arm_exit(ptr addrspace(1) %obj, i1 %p) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 0, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  br i1 %p, label %covered, label %uncovered

covered:
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret void

uncovered:
  store i32 2, ptr addrspace(1) %obj
  ret void
}
