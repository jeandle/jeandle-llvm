; RUN: opt -S -passes='lock-coarsening' %s | FileCheck %s
; RUN: opt -S -passes='lock-coarsening' %s | grep -c 'call hotspotcc void @jeandle.monitorenter_with_thin_lock' | FileCheck %s --check-prefix=ENTER-COUNT
; RUN: opt -S -passes='lock-coarsening' %s | grep -c 'call hotspotcc void @jeandle.monitorexit_with_thin_lock' | FileCheck %s --check-prefix=EXIT-COUNT

; Final CFG coarsening target.  The two functions model C2's fully-redundant
; cases: every path through the diamond is protected, so the outer lock can
; cover the whole conditional and all inner regions can be removed.
;
; ENTER-COUNT: 2
; EXIT-COUNT: 2

declare void @llvm.lifetime.start.p0(ptr captures(none))
declare void @llvm.lifetime.end.p0(ptr captures(none))

declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind

; CHECK-LABEL: define void @if_then_else_fully_redundant(
; CHECK: %lock0 = alloca i64
; CHECK-NOT: %lock{{[1-9]}} = alloca
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK-NOT: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK-NOT: call hotspotcc void @jeandle.monitorexit_with_thin_lock
; CHECK: store i32 1, ptr addrspace(1) %obj
; CHECK: store i32 2, ptr addrspace(1) %obj
; CHECK: store i32 3, ptr addrspace(1) %obj
; CHECK: store i32 4, ptr addrspace(1) %obj
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
define void @if_then_else_fully_redundant(ptr addrspace(1) %obj, i1 %p) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  %lock2 = alloca i64
  %lock3 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  br i1 %p, label %then, label %otherwise

then:
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  br label %merge

otherwise:
  call void @llvm.lifetime.start.p0(ptr %lock2)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
  store i32 3, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
  call void @llvm.lifetime.end.p0(ptr %lock2)
  br label %merge

merge:
  call void @llvm.lifetime.start.p0(ptr %lock3)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock3)
  store i32 4, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock3)
  call void @llvm.lifetime.end.p0(ptr %lock3)
  ret void
}

; CHECK-LABEL: define void @if_then_fully_redundant(
; CHECK: %lock0 = alloca i64
; CHECK-NOT: %lock{{[1-9]}} = alloca
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK-NOT: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK-NOT: call hotspotcc void @jeandle.monitorexit_with_thin_lock
; CHECK: store i32 1, ptr addrspace(1) %obj
; CHECK: store i32 2, ptr addrspace(1) %obj
; CHECK: store i32 3, ptr addrspace(1) %obj
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
define void @if_then_fully_redundant(ptr addrspace(1) %obj, i1 %p) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  %lock2 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  br i1 %p, label %then, label %merge

then:
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  br label %merge

merge:
  call void @llvm.lifetime.start.p0(ptr %lock2)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
  store i32 3, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
  call void @llvm.lifetime.end.p0(ptr %lock2)
  ret void
}
