; RUN: opt -S -passes="lock-coarsening" %s | FileCheck %s --check-prefix=CHECK
; RUN: opt -S -passes="lock-coarsening" %s -jeandle-lock-coarsening=false | FileCheck %s --check-prefix=CHECK-OFF

; The first region may leave its enter block when a guarded call is inlined
; inside the first synchronized block:
;
;   synchronized (this) { result += a; result += maybeThrow(t); }
;   synchronized (this) { result += b; }
;
; The guard's failure edge deoptimizes while the retained monitor is still
; live; only the normal edge reaches the first exit.  Both regions then fold
; into one acquisition.  This is the first-region counterpart of
; guarded-second-region.ll.

declare void @llvm.lifetime.start.p0(ptr captures(none))
declare void @llvm.lifetime.end.p0(ptr captures(none))
declare hotspotcc i32 @llvm.experimental.deoptimize.i32(...)

declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc ptr addrspace(1) @jeandle.current_thread_obj() nounwind memory(none) willreturn
declare void @opaque(ptr)

; CHECK-LABEL: define hotspotcc i32 @first_region_cfg(
; CHECK: %lock0 = alloca i64
; CHECK-NOT: %lock1 = alloca
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK-NOT: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.current_thread_obj()
; CHECK: br i1 %is_null, label %null_check_fail, label %normal
; CHECK: null_check_fail:
; CHECK-NEXT: %deopt = call hotspotcc i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) [ "deopt"(i32 40, i32 40, i64 196620, ptr addrspace(1) %obj, ptr %lock0) ]
; CHECK-NEXT: ret i32 %deopt
; CHECK: normal:
; CHECK: %b = load atomic i32, ptr addrspace(1) %obj seq_cst, align 4
; CHECK: %result = add i32 %a, %b
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: ret i32 %result
;
; CHECK-OFF-LABEL: define hotspotcc i32 @first_region_cfg(
; CHECK-OFF: %lock1 = alloca i64
; CHECK-OFF: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
define hotspotcc i32 @first_region_cfg(ptr addrspace(1) %obj) personality ptr @jeandle.personality {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  %a = load atomic i32, ptr addrspace(1) %obj seq_cst, align 4
  %thread = call hotspotcc ptr addrspace(1) @jeandle.current_thread_obj()
  %is_null = icmp eq ptr addrspace(1) %thread, null
  br i1 %is_null, label %null_check_fail, label %normal

null_check_fail:
  %deopt = call hotspotcc i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) [ "deopt"(i32 40, i32 40, i64 196620, ptr addrspace(1) %obj, ptr %lock0) ]
  ret i32 %deopt

normal:
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  %b = load atomic i32, ptr addrspace(1) %obj seq_cst, align 4
  %result = add i32 %a, %b
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret i32 %result
}

; A first region with two normal exits is deliberately unsupported: the
; rewrite would have to keep a live acquisition across both paths.  The two
; enters must remain separate.
; CHECK-LABEL: define hotspotcc i32 @first_region_two_normal_exits(
; CHECK: %lock1 = alloca i64
; CHECK: %lock2 = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
define hotspotcc i32 @first_region_two_normal_exits(ptr addrspace(1) %obj, i1 %cond) {
entry:
  %lock1 = alloca i64
  %lock2 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  br i1 %cond, label %left, label %right

left:
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  br label %join

right:
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  br label %join

join:
  call void @llvm.lifetime.end.p0(ptr %lock1)
  call void @llvm.lifetime.start.p0(ptr %lock2)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
  call void @llvm.lifetime.end.p0(ptr %lock2)
  ret i32 0
}

; A loop in the first region is unsupported: the enter must not move across a
; back edge.
; CHECK-LABEL: define hotspotcc i32 @first_region_loop(
; CHECK: %lock1 = alloca i64
; CHECK: %lock2 = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
define hotspotcc i32 @first_region_loop(ptr addrspace(1) %obj, i1 %cond) {
entry:
  %lock1 = alloca i64
  %lock2 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  br label %head

head:
  br i1 %cond, label %body, label %exit

body:
  call void @opaque(ptr %lock1)
  br label %head

exit:
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  call void @llvm.lifetime.start.p0(ptr %lock2)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
  call void @llvm.lifetime.end.p0(ptr %lock2)
  ret i32 0
}

; A deopt-terminating block that performs a monitor operation is not a pure
; frame exit and must not be accepted.
; CHECK-LABEL: define hotspotcc i32 @first_region_deopt_with_monitor(
; CHECK: %lock1 = alloca i64
; CHECK: %lock2 = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
define hotspotcc i32 @first_region_deopt_with_monitor(ptr addrspace(1) %obj, i1 %cond) {
entry:
  %lock1 = alloca i64
  %lock2 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  br i1 %cond, label %fail, label %normal

fail:
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  %deopt = call hotspotcc i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) [ "deopt"(i32 40, i32 40, i64 196620, ptr addrspace(1) %obj, ptr %lock1) ]
  ret i32 %deopt

normal:
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  call void @llvm.lifetime.start.p0(ptr %lock2)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock2)
  call void @llvm.lifetime.end.p0(ptr %lock2)
  ret i32 0
}

declare ptr @jeandle.personality(...)
