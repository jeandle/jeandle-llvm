; RUN: opt -S -passes=lock-coarsening %s | FileCheck %s
; RUN: opt -S -passes=lock-coarsening %s | grep -c "call hotspotcc void @jeandle.monitorenter_with_thin_lock" | FileCheck %s --check-prefix=ENTER-COUNT
; RUN: opt -S -passes=lock-coarsening %s | grep -c "call hotspotcc void @jeandle.monitorexit_with_thin_lock" | FileCheck %s --check-prefix=EXIT-COUNT

; recursive_method_calls after inlining.  A synchronized recursive method
; acquires the receiver again in the inlined callee.  The inner enter carries a
; deopt bundle and the inner region exits normally and exceptionally.  The
; redundant inner acquire must disappear while both paths release the outer
; BasicLock.

; ENTER-COUNT: 1
; EXIT-COUNT: 2

declare void @llvm.lifetime.start.p0(ptr captures(none))
declare void @llvm.lifetime.end.p0(ptr captures(none))
declare i32 @__gxx_personality_v0(...)

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1, i1, i1)
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind

; CHECK-LABEL: define i32 @recursive_nested(
; CHECK: %lock0 = alloca i64
; CHECK-NOT: %lock1 = alloca
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0) [ "deopt"(
; CHECK-NOT: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK: %call = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: normal:
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: unwind.inner:
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
define i32 @recursive_nested(ptr addrspace(1) %obj, ptr %klass, i32 %value) personality ptr @__gxx_personality_v0 {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0) [ "deopt"(i64 0, i32 -1, i32 -1, i64 12, ptr addrspace(1) %obj, ptr %lock0) ]
  %next = add i32 %value, 1
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1) [ "deopt"(i64 0, i32 15, i32 15, i64 12, ptr addrspace(1) %obj, ptr %lock1) ]
  %call = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr %klass, i32 16, i1 false, i1 false, i1 false) to label %normal unwind label %unwind.inner

normal:
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  %sum = add i32 %next, 1
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  ret i32 %sum

unwind.inner:
  %lp = landingpad i64 cleanup
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  resume i64 %lp
}
