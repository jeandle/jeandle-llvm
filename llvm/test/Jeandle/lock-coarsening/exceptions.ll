; RUN: opt -S -passes='lock-coarsening' %s | FileCheck %s
; RUN: opt -S -passes='lock-coarsening' %s | grep -c 'call hotspotcc void @jeandle.monitorenter_with_thin_lock' | FileCheck %s --check-prefix=ENTER-COUNT
; RUN: opt -S -passes='lock-coarsening' %s | grep -c 'call hotspotcc void @jeandle.monitorexit_with_thin_lock' | FileCheck %s --check-prefix=EXIT-COUNT

; Exceptional exits.  Coarsening may remove the inner region only if the
; retained slot is released on both the normal and the unwind path.  This test
; deliberately keeps the exceptional edge visible in IR.
;
; The candidate and every exit must handle the visible invoke edge.

; ENTER-COUNT: 2
; EXIT-COUNT: 4

declare void @llvm.lifetime.start.p0(ptr captures(none))
declare void @llvm.lifetime.end.p0(ptr captures(none))
declare i32 @__gxx_personality_v0(...)

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1, i1, i1)
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind

; CHECK-LABEL: define void @unwind_second_region(
; CHECK: %lock0 = alloca i64
; CHECK-NOT: %lock1 = alloca
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK-NOT: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK: %alloc = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: unwind.second:
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
define void @unwind_second_region(ptr addrspace(1) %obj, ptr %klass) personality ptr @__gxx_personality_v0 {
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

; CHECK-LABEL: define void @unwind_then_catch_dispatch(
; CHECK: %lock0 = alloca i64
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK-NOT: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK: invoke hotspotcc i32 @exceptional.body() [ "deopt"(i32 99, i32 99, i64 196620, ptr addrspace(1) %obj, ptr %lock0) ]
; CHECK: normal:
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: unwind:
; CHECK: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
; CHECK: catch.dispatch:
; CHECK: call hotspotcc i32 @jeandle.instanceof
;
; The unwind edge can continue into Java catch dispatch after releasing the
; second monitor.  Instructions there are outside the protected region and
; must not make the candidate look unsafe merely because a dispatch helper is
; an ordinary, non-deopt call.
define void @unwind_then_catch_dispatch(ptr addrspace(1) %obj, ptr %klass) personality ptr @__gxx_personality_v0 {
entry:
  %lock0 = alloca i64

  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  store i32 1, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  br label %second

second:
  call void @llvm.lifetime.start.p0(ptr %lock0)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  %value = invoke hotspotcc i32 @"exceptional.body"()
      [ "deopt"(i32 99, i32 99, i64 196620, ptr addrspace(1) %obj, ptr %lock0) ]
      to label %normal unwind label %unwind

normal:
  store i32 %value, ptr addrspace(1) %obj
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  ret void

unwind:
  %lp = landingpad i64 cleanup
  %exc = load volatile ptr addrspace(1), ptr addrspace(2) inttoptr (i64 1272 to ptr addrspace(2))
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %obj, ptr %lock0)
  call void @llvm.lifetime.end.p0(ptr %lock0)
  br label %catch.dispatch

catch.dispatch:
  %is_match = call hotspotcc i32 @jeandle.instanceof(ptr %klass, ptr addrspace(1) %exc)
  %matched = icmp eq i32 %is_match, 1
  br i1 %matched, label %handler, label %rethrow

handler:
  ret void

rethrow:
  resume i64 %lp
}

declare hotspotcc i32 @"exceptional.body"()
declare hotspotcc i32 @jeandle.instanceof(ptr, ptr addrspace(1))
