; RUN: opt -S -passes='lock-coarsening' %s | FileCheck %s
; RUN: opt -S -passes='lock-coarsening' %s | grep -c 'monitorenter_with_thin_lock' | FileCheck %s --check-prefix=ENTER-COUNT
; RUN: opt -S -passes='lock-coarsening' %s | grep -c 'monitorexit_with_thin_lock' | FileCheck %s --check-prefix=EXIT-COUNT

; ENTER-COUNT: 2
; EXIT-COUNT: 4

declare void @llvm.lifetime.start.p0(ptr captures(none))
declare void @llvm.lifetime.end.p0(ptr captures(none))
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc i32 @llvm.experimental.deoptimize.i32(...)

define i32 @conditional_chain(ptr addrspace(1) %obj, i1 %p) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  %lock2 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  br i1 %p, label %early1, label %next1
early1:
  %e1 = call hotspotcc i32 (...) @llvm.experimental.deoptimize.i32(i32 -1) [ "deopt"(i32 99, i32 99, i64 196620, ptr addrspace(1) %obj, ptr %lock0) ]
  ret i32 %e1
next1:
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  br i1 %p, label %early2, label %next2
early2:
  %e2 = call hotspotcc i32 (...) @llvm.experimental.deoptimize.i32(i32 -2) [ "deopt"(i32 99, i32 99, i64 196620, ptr addrspace(1) %obj, ptr %lock0) ]
  ret i32 %e2
next2:
  call void @llvm.lifetime.start.p0(ptr %lock2)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
  call void @llvm.lifetime.end.p0(ptr %lock2)
  ret i32 0
}

; CHECK-LABEL: define i32 @conditional_chain
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK-NOT: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK: early1:
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK-NEXT: call hotspotcc i32 (...) @llvm.experimental.deoptimize.i32
; CHECK: early2:
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK-NEXT: call hotspotcc i32 (...) @llvm.experimental.deoptimize.i32
; CHECK: next2:
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK-NEXT: call void @llvm.lifetime.end.p0(ptr %lock0)
; CHECK-NEXT: ret i32 0
