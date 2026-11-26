; RUN: opt -S -passes='lock-coarsening' %s | FileCheck %s --check-prefix=CHECK
; RUN: opt -S -passes='lock-coarsening' %s -jeandle-lock-coarsening=false | FileCheck %s --check-prefix=CHECK-OFF

; A frontend inline expansion can let several copies of a guarded region share
; one deopt sink.  The sink terminates the frame and contains no monitor
; operation, so it does not observe the rewritten lock.  This is the shape
; produced when the benchmark method is inlined into a JMH loop stub.

declare void @llvm.lifetime.start.p0(ptr captures(none))
declare void @llvm.lifetime.end.p0(ptr captures(none))
declare hotspotcc i32 @llvm.experimental.deoptimize.i32(...)

declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
@thread = external global ptr

; Mirrors the real JIT: a private helper with a read-only body and no memory
; attributes on the call site.  The pass must prove it from the body.
define private hotspotcc ptr addrspace(1) @jeandle.current_thread_obj() nounwind {
entry:
  %thread = load ptr, ptr @thread
  %obj = load ptr addrspace(1), ptr %thread
  ret ptr addrspace(1) %obj
}
declare void @sink(ptr)

; CHECK-LABEL: define hotspotcc i32 @shared_deopt_sink(
; CHECK: %lock = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock)
; CHECK-NOT: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK: normal:
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock)
; CHECK: shared.sink:
; CHECK: %deopt = call hotspotcc i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) [ "deopt"(i32 40, i32 40, i64 196620, ptr addrspace(1) %obj, ptr %lock) ]
; CHECK-NEXT: ret i32 %deopt
;
; CHECK-OFF-LABEL: define hotspotcc i32 @shared_deopt_sink(
; CHECK-OFF: %lock = alloca i64
; CHECK-OFF: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock)
; CHECK-OFF: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock)
define hotspotcc i32 @shared_deopt_sink(ptr addrspace(1) %obj, i1 %shared, i1 %go) personality ptr @jeandle.personality {
entry:
  %lock = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock)
  call void @llvm.lifetime.end.p0(ptr %lock)

  call void @llvm.lifetime.start.p0(ptr %lock)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock)
  %thread = call hotspotcc ptr addrspace(1) @jeandle.current_thread_obj()
  %is_null = icmp eq ptr addrspace(1) %thread, null
  br i1 %is_null, label %shared.sink, label %normal

normal:
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock)
  call void @llvm.lifetime.end.p0(ptr %lock)
  ret i32 0

; A second inlined copy reaches the same deopt sink.  It is outside the
; candidate region, so the sink is shared.
outside:
  br label %shared.sink

shared.sink:
  %deopt = call hotspotcc i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) [ "deopt"(i32 40, i32 40, i64 196620, ptr addrspace(1) %obj, ptr %lock) ]
  ret i32 %deopt
}

; A shared block that performs work beyond deopt/return is not accepted.
; CHECK-LABEL: define hotspotcc i32 @shared_sink_with_work(
; CHECK: %lock = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock)
define hotspotcc i32 @shared_sink_with_work(ptr addrspace(1) %obj, i1 %go) personality ptr @jeandle.personality {
entry:
  %lock = alloca i64
  call void @llvm.lifetime.start.p0(ptr %lock)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock)
  call void @llvm.lifetime.end.p0(ptr %lock)

  call void @llvm.lifetime.start.p0(ptr %lock)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock)
  %thread = call hotspotcc ptr addrspace(1) @jeandle.current_thread_obj()
  %is_null = icmp eq ptr addrspace(1) %thread, null
  br i1 %is_null, label %shared.work, label %normal

normal:
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock)
  call void @llvm.lifetime.end.p0(ptr %lock)
  ret i32 0

outside:
  br label %shared.work

shared.work:
  call void @sink(ptr %lock)
  %deopt = call hotspotcc i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) [ "deopt"(i32 40, i32 40, i64 196620, ptr addrspace(1) %obj, ptr %lock) ]
  ret i32 %deopt
}

declare ptr @jeandle.personality(...)
