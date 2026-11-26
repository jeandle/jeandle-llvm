; RUN: opt -S -passes='lock-coarsening' %s | FileCheck %s

; Exceptional exits must be handled identically for all three
; locking modes.  Each function has one inner monitor region containing an
; invoke; both its normal and unwind paths release the inner slot.

declare void @llvm.lifetime.start.p0(ptr captures(none))
declare void @llvm.lifetime.end.p0(ptr captures(none))
declare i32 @__gxx_personality_v0(...)

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1, i1, i1)
declare hotspotcc void @jeandle.monitorenter_with_monitor_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_monitor_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind

; CHECK-LABEL: define void @monitor_mode_unwind(
; CHECK: %lock0 = alloca i64
; CHECK-NOT: %lock1 = alloca
; CHECK: call hotspotcc void @jeandle.monitorenter_with_monitor_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call hotspotcc void @jeandle.monitorexit_with_monitor_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: unwind.second:
; CHECK: call hotspotcc void @jeandle.monitorexit_with_monitor_lock(ptr addrspace(1) %obj, ptr %lock0)
define void @monitor_mode_unwind(ptr addrspace(1) %obj, ptr %klass) personality ptr @__gxx_personality_v0 {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_monitor_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_monitor_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_monitor_lock(ptr addrspace(1) %obj, ptr %lock1)
  %alloc = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr %klass, i32 16, i1 false, i1 false, i1 false)
      to label %after unwind label %unwind.second
after:
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_monitor_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret void
unwind.second:
  %lp = landingpad i64 cleanup
  call hotspotcc void @jeandle.monitorexit_with_monitor_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  resume i64 %lp
}

; CHECK-LABEL: define void @thin_mode_unwind(
; CHECK: %lock0 = alloca i64
; CHECK-NOT: %lock1 = alloca
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: unwind.second:
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
define void @thin_mode_unwind(ptr addrspace(1) %obj, ptr %klass) personality ptr @__gxx_personality_v0 {
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
  %alloc = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr %klass, i32 16, i1 false, i1 false, i1 false)
      to label %after unwind label %unwind.second
after:
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret void
unwind.second:
  %lp = landingpad i64 cleanup
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  resume i64 %lp
}

; CHECK-LABEL: define void @lightweight_mode_unwind(
; CHECK: %lock0 = alloca i64
; CHECK-NOT: %lock1 = alloca
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: unwind.second:
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %obj, ptr %lock0)
define void @lightweight_mode_unwind(ptr addrspace(1) %obj, ptr %klass) personality ptr @__gxx_personality_v0 {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %obj, ptr %lock1)
  %alloc = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr %klass, i32 16, i1 false, i1 false, i1 false)
      to label %after unwind label %unwind.second
after:
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret void
unwind.second:
  %lp = landingpad i64 cleanup
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  resume i64 %lp
}
