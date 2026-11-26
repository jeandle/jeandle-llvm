; RUN: opt -S -passes='lock-coarsening' %s | FileCheck %s
; RUN: opt -S -passes='lock-coarsening' %s | grep -c 'call hotspotcc void @jeandle.monitorenter_with_thin_lock' | FileCheck %s --check-prefix=ENTER-COUNT
; RUN: opt -S -passes='lock-coarsening' %s | grep -c 'call hotspotcc void @jeandle.monitorexit_with_thin_lock' | FileCheck %s --check-prefix=EXIT-COUNT

; Fairness guardrail.  Two adjacent regions in one loop iteration may be
; merged, but the retained critical section must stay inside the loop and must
; not be held across the backedge.

; ENTER-COUNT: 1
; EXIT-COUNT: 1

declare void @llvm.lifetime.start.p0(ptr captures(none))
declare void @llvm.lifetime.end.p0(ptr captures(none))

declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind

; CHECK-LABEL: define void @loop_body_two_regions(
; CHECK: entry:
; CHECK: %lock0 = alloca i64
; CHECK-NOT: %lock1 = alloca
; CHECK-NOT: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK: loop:
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK-NOT: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK-NOT: call hotspotcc void @jeandle.monitorexit_with_thin_lock
; CHECK: store i32 1, ptr addrspace(1) %obj
; CHECK: store i32 2, ptr addrspace(1) %obj
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: br i1 %again, label %loop, label %exit
; CHECK: exit:
; CHECK-NOT: call hotspotcc void @jeandle.monitorexit_with_thin_lock
define void @loop_body_two_regions(ptr addrspace(1) %obj, i1 %again) {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  br label %loop

loop:
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  br i1 %again, label %loop, label %exit

exit:
  ret void
}
