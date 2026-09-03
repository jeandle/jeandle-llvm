; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s -o %t
; RUN: FileCheck %s < %t
; RUN: not grep '!jeandle[.]pea[.]replay' %t

; A structured monitor spans a potentially throwing invoke. The normal invoke
; edge and f escape path merge at m and leave through one common exit; the
; unwind handler has its own exit. Replay for t->m must not execute on t->h,
; where the virtual enter/exit pair is eliminated together.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @foo()
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @hazard_folded_exit_dominated(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lk = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
              ptr addrspace(1) %o, ptr %lk)
  br i1 %c, label %t, label %f
t:
  invoke void @foo() to label %m unwind label %h
f:
  call void @sink(ptr addrspace(1) %o)
  br label %m
m:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
              ptr addrspace(1) %o, ptr %lk)
  ret void
h:
  %lp = landingpad i64 cleanup
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
              ptr addrspace(1) %o, ptr %lk)
  resume i64 %lp
u:
  %lpr = landingpad i64 cleanup
  resume i64 %lpr
}

; The two normal paths each replay one enter and share m's real exit. The
; unwind path contains neither enter nor exit after virtual elimination.
; CHECK-LABEL: define void @hazard_folded_exit_dominated(
; CHECK: n:
; CHECK-NEXT: br i1 %c, label %t, label %f
; CHECK: t:
; CHECK-NEXT: invoke void @foo()
; CHECK-NEXT: to label %[[EDGE:[-A-Za-z$._0-9]+]] unwind label %h
; CHECK: f:
; CHECK-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %o, ptr %lk)
; CHECK-NEXT: call void @sink(ptr addrspace(1) %o)
; CHECK-NEXT: br label %m
; CHECK: [[EDGE]]:
; CHECK-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %o, ptr %lk)
; CHECK-NEXT: br label %m
; CHECK: m:
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %o, ptr %lk)
; CHECK-NEXT: ret void
; CHECK: h:
; CHECK-NOT: @jeandle.monitor
; CHECK: resume i64 %lp
; CHECK: u:
; CHECK-NOT: @jeandle.monitor
; CHECK-NOT: pea.mat
; CHECK-NOT: poison
; CHECK: }

!java-method-compilation = !{}
