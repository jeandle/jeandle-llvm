; RUN: opt -S -passes='lock-coarsening' %s | FileCheck %s --check-prefix=CHECK
; RUN: opt -S -passes='lock-coarsening' %s -jeandle-lock-coarsening=false | FileCheck %s --check-prefix=CHECK-OFF

; Regression: the second region is not a straight line.  It contains a
; nounwind memory(none) frontend helper followed by a guarded branch whose two
; failure edges deopt and whose normal edge reaches the monitor exit.  This is
; the IR emitted for:
;
;   synchronized (this) { result += a; }
;   try { synchronized (this) { result += b; result += maybeThrow(); } }
;   catch (IllegalStateException e) { return -1; }
;
; C2 and Graal both eliminate the second monitor here; the deopt records keep
; describing the retained lock, so no unlock is emitted on the deopt edges.

declare void @llvm.lifetime.start.p0(ptr captures(none))
declare void @llvm.lifetime.end.p0(ptr captures(none))
declare hotspotcc i32 @llvm.experimental.deoptimize.i32(...)

declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc ptr addrspace(1) @jeandle.current_thread_obj() nounwind memory(none) willreturn

declare void @opaque(ptr)

; CHECK-LABEL: define hotspotcc i32 @guarded_second_region(
; CHECK: %lock0 = alloca i64
; CHECK-NOT: %lock1 = alloca
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK-NOT: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK: %thread = call hotspotcc ptr addrspace(1) @jeandle.current_thread_obj()
; CHECK: br i1 %is_null, label %null_check_fail, label %receiver_check
; CHECK: null_check_fail:
; CHECK-NEXT: %deopt1 = call hotspotcc i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) [ "deopt"(i32 40, i32 40, i64 196620, ptr addrspace(1) %obj, ptr %lock0) ]
; CHECK-NEXT: ret i32 %deopt1
; CHECK: receiver_check:
; CHECK: br i1 %stable, label %normal, label %unstable
; CHECK: unstable:
; CHECK-NEXT: %deopt2 = call hotspotcc i32 (...) @llvm.experimental.deoptimize.i32(i32 -187) [ "deopt"(i32 40, i32 40, i64 196620, ptr addrspace(1) %obj, ptr %lock0) ]
; CHECK-NEXT: ret i32 %deopt2
; CHECK: normal:
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: ret i32 %result
;
; CHECK-OFF-LABEL: define hotspotcc i32 @guarded_second_region(
; CHECK-OFF: %lock0 = alloca i64
; CHECK-OFF: %lock1 = alloca i64
; CHECK-OFF: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
define hotspotcc i32 @guarded_second_region(ptr addrspace(1) %obj) personality ptr @jeandle.personality {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  %a = load atomic i32, ptr addrspace(1) %obj seq_cst, align 4
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)

  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  %b = load atomic i32, ptr addrspace(1) %obj seq_cst, align 4
  %result = add i32 %a, %b
  %thread = call hotspotcc ptr addrspace(1) @jeandle.current_thread_obj()
  %is_null = icmp eq ptr addrspace(1) %thread, null
  br i1 %is_null, label %null_check_fail, label %receiver_check

null_check_fail:
  %deopt1 = call hotspotcc i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) [ "deopt"(i32 40, i32 40, i64 196620, ptr addrspace(1) %obj, ptr %lock1) ]
  ret i32 %deopt1

receiver_check:
  %flag = getelementptr inbounds nuw i8, ptr addrspace(1) %thread, i64 58
  %stable_value = load atomic i8, ptr addrspace(1) %flag seq_cst, align 1
  %stable = icmp eq i8 %stable_value, 0
  br i1 %stable, label %normal, label %unstable

unstable:
  %deopt2 = call hotspotcc i32 (...) @llvm.experimental.deoptimize.i32(i32 -187) [ "deopt"(i32 40, i32 40, i64 196620, ptr addrspace(1) %obj, ptr %lock1) ]
  ret i32 %deopt2

normal:
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret i32 %result
}

; A region with an opaque, memory-writing call on a path to the deopt is not
; a safe coarsening candidate.
; CHECK-LABEL: define hotspotcc i32 @opaque_on_deopt_path(
; CHECK: %lock0 = alloca i64
; CHECK: %lock1 = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
; CHECK: call void @opaque(ptr %lock1)
define hotspotcc i32 @opaque_on_deopt_path(ptr addrspace(1) %obj) personality ptr @jeandle.personality {
entry:
  %lock0 = alloca i64
  %lock1 = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)

  call void @llvm.lifetime.start.p0(ptr %lock1)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @opaque(ptr %lock1)
  br i1 true, label %fail, label %normal

fail:
  %deopt = call hotspotcc i32 (...) @llvm.experimental.deoptimize.i32(i32 -7) [ "deopt"(i32 40, i32 40, i64 196620, ptr addrspace(1) %obj, ptr %lock1) ]
  ret i32 %deopt

normal:
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock1)
  call void @llvm.lifetime.end.p0(ptr %lock1)
  ret i32 0
}

declare ptr @jeandle.personality(...)
