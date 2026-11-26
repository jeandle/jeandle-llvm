; RUN: opt -S -passes='lock-coarsening' %s | FileCheck %s

; Negative cases: every exceptional path leaving the second region
; must release the retained monitor slot.  Otherwise the candidate must be
; rejected and the original BasicLock slots must survive.

declare void @llvm.lifetime.start.p0(ptr captures(none))
declare void @llvm.lifetime.end.p0(ptr captures(none))
declare i32 @__gxx_personality_v0(...)

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1, i1, i1)
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind

; The unwind edge must also release the retained slot.  If it only resumes,
; merging would leak the lock on the exceptional path.
; CHECK-LABEL: define void @missing_unwind_exit(
; CHECK: %lock0 = alloca i64
; CHECK: %lock1 = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: unwind.missing:
; CHECK: resume i64 %lp
define void @missing_unwind_exit(ptr addrspace(1) %obj, ptr %klass) personality ptr @__gxx_personality_v0 {
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
      to label %after unwind label %unwind.missing

after:
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret void

unwind.missing:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A different monitor object on the unwind edge is not the same region exit.
; CHECK-LABEL: define void @mismatched_unwind_exit(
; CHECK: %lock0 = alloca i64
; CHECK: %lock1 = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; CHECK: unwind.mismatched:
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %other, ptr %lock1)
define void @mismatched_unwind_exit(ptr addrspace(1) %obj, ptr addrspace(1) %other, ptr %klass) personality ptr @__gxx_personality_v0 {
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
      to label %after unwind label %unwind.mismatched

after:
  store i32 2, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret void

unwind.mismatched:
  %lp = landingpad i64 cleanup
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %other, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  resume i64 %lp
}
