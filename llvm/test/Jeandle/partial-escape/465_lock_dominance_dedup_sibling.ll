; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s -o %t
; RUN: FileCheck %s < %t
; RUN: not grep '!jeandle[.]pea[.]replay' %t

; Three disjoint dynamic paths escape one virtually locked object: q at foo,
; p->s at baz, and p->merge1 on the incoming edge. Each path needs its own
; replayed enter, followed by the single structured exit in merge1. A replay
; on p itself would incorrectly also execute on p->s and double-acquire there.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @foo(ptr addrspace(1))
declare void @baz(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @s_path(i1 %c0, i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lo = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
              ptr addrspace(1) %o, ptr %lo)
  br i1 %c0, label %p, label %q
p:
  br i1 %c, label %merge1, label %s
q:
  call void @foo(ptr addrspace(1) %o)
  br label %merge1
s:
  call void @baz(ptr addrspace(1) %o)
  br label %merge1
merge1:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
              ptr addrspace(1) %o, ptr %lo)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Exactly three re-emitted enters survive, one on each disjoint escape path,
; and merge1 retains exactly one common exit.
; CHECK-LABEL: define void @s_path(
; CHECK: p:
; CHECK-NEXT: br i1 %c, label %[[EDGE:[-A-Za-z$._0-9]+]], label %s
; CHECK: q:
; CHECK-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %o, ptr %lo)
; CHECK-NEXT: call void @foo(ptr addrspace(1) %o)
; CHECK-NEXT: br label %merge1
; CHECK: s:
; CHECK-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %o, ptr %lo)
; CHECK-NEXT: call void @baz(ptr addrspace(1) %o)
; CHECK-NEXT: br label %merge1
; CHECK: [[EDGE]]:
; CHECK-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %o, ptr %lo)
; CHECK-NEXT: br label %merge1
; CHECK: merge1:
; CHECK-NEXT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %o, ptr %lo)
; CHECK-NEXT: ret void
; CHECK: u:
; CHECK-NOT: @jeandle.monitor
; CHECK-NOT: poison
; CHECK: }

!java-method-compilation = !{}
