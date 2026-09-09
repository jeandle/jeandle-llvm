; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" %s -o %t
; RUN: FileCheck %s < %t
; RUN: not grep '!jeandle[.]pea[.]replay' %t

; A merge-driven materialization at t belongs separately to t->m and t->h.
; The normal replay joins f's direct escape before z; the unwind replay is
; inserted after a cloned landingpad before entering shared handler h. Thus
; every path reaching the real exits at zok/h has exactly one real acquire.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @foo(ptr addrspace(1))
declare void @bar()
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @late_handler(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lk = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
              ptr addrspace(1) %o, ptr %lk)
  %p = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
       to label %np unwind label %u.locked
np:
  br i1 %c, label %t, label %f
t:
  invoke void @foo(ptr addrspace(1) %p) to label %m unwind label %h
f:
  call void @sink(ptr addrspace(1) %o)
  br label %m
m:
  br label %z
z:
  invoke void @bar() to label %zok unwind label %h
zok:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
              ptr addrspace(1) %o, ptr %lk)
  ret void
h:
  %lp = landingpad i64 cleanup
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
              ptr addrspace(1) %o, ptr %lk)
  resume i64 %lp
u.locked:
  %locked.lp = landingpad i64 cleanup
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
              ptr addrspace(1) %o, ptr %lk)
  resume i64 %locked.lp
u:
  %lpr = landingpad i64 cleanup
  resume i64 %lpr
}

; CHECK-LABEL: define void @late_handler(
; CHECK-LABEL: t:
; CHECK: invoke void @foo(ptr addrspace(1) %p)
; CHECK-NEXT: to label %[[NORMAL_EDGE:[-A-Za-z$._0-9]+]] unwind label %[[UNWIND_EDGE:[-A-Za-z$._0-9]+]]
; CHECK-LABEL: f:
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %o, ptr %lk)
; CHECK-NEXT: call void @sink(ptr addrspace(1) %o)
; CHECK: [[NORMAL_EDGE]]:
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %o, ptr %lk)
; CHECK-NEXT: br label %m
; CHECK-LABEL: zok:
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %o, ptr %lk)
; CHECK: [[UNWIND_EDGE]]:
; CHECK-NEXT: %{{[-A-Za-z$._0-9]+}} = landingpad i64
; CHECK-NEXT: cleanup
; CHECK-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %o, ptr %lk)
; CHECK-NEXT: br label %h
; CHECK-LABEL: h:
; CHECK: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %o, ptr %lk)
; CHECK-NOT: pea.mat
; CHECK-NOT: poison

!java-method-compilation = !{}
