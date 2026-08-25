; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s -o %t
; RUN: FileCheck %s --check-prefixes=CHECK,SWITCH,EH,MIXED < %t
; RUN: not grep '!jeandle[.]pea[.]replay' %t

; A merge-driven materialization belongs to the incoming control-flow edge,
; not to every successor of its predecessor.  The left predecessor below has
; an early-return edge as well as an edge to the identity-observing merge.
; Field replay and the interleaved a@0,b@1,a@2 lock replay must execute only on
; the edge to %merge.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare void @may_throw()
declare i32 @__gxx_personality_v0(...)

define i32 @critical_edge_replay(i1 %choose.left, i1 %early)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a.lock0 = alloca i64, align 8
  %b.lock1 = alloca i64, align 8
  %a.lock2 = alloca i64, align 8
  %r.lock3 = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 60101 to ptr), i32 24, i1 false)
       to label %alloc.b unwind label %unwind
alloc.b:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 60102 to ptr), i32 24, i1 false)
       to label %alloc.c unwind label %unwind
alloc.c:
  %c = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 60103 to ptr), i32 24, i1 false)
       to label %locked unwind label %unwind
locked:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %a.lock0)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %b, ptr %b.lock1)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %a.lock2)
  br i1 %choose.left, label %left, label %right
left:
  %b.slot = getelementptr inbounds i8, ptr addrspace(1) %b, i64 16
  store atomic i32 21, ptr addrspace(1) %b.slot unordered, align 4
  br i1 %early, label %early.exit, label %merge
right:
  %c.slot = getelementptr inbounds i8, ptr addrspace(1) %c, i64 16
  store atomic i32 31, ptr addrspace(1) %c.slot unordered, align 4
  br label %merge
merge:
  %r = phi ptr addrspace(1) [ %b, %left ], [ %c, %right ]
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %r, ptr %r.lock3)
  call void @sink(ptr addrspace(1) %r)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %r, ptr %r.lock3)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %a.lock2)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %b, ptr %b.lock1)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %a.lock0)
  ret i32 1
early.exit:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %a.lock2)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %b, ptr %b.lock1)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %a.lock0)
  ret i32 0
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The critical predecessor itself contains no replay, so its early successor
; cannot acquire a real monitor whose virtual exits have been folded.
; CHECK-LABEL: define i32 @critical_edge_replay(
; CHECK-LABEL: left:
; CHECK: br i1 %early, label %early.exit, label %[[EDGE:[-A-Za-z$._0-9]+]]
; CHECK: [[EDGE]]:
; CHECK: store atomic i32 21, ptr addrspace(1) %{{[-A-Za-z$._0-9]+}} unordered, align 4
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %a, ptr %a.lock0)
; CHECK-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %b, ptr %b.lock1)
; CHECK-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %a, ptr %a.lock2)
; CHECK: br label %merge
; CHECK-LABEL: early.exit:
; CHECK-NOT: jeandle.monitorenter
; CHECK-NOT: jeandle.monitorexit
; CHECK: ret i32 0

; A state-only materialization and a field-replaying materialization can share
; one critical incoming edge. Only the latter requires runtime instructions,
; but splitting that edge must still rewrite both pointer PHIs consistently.
define void @mixed_empty_and_nonempty_replay(i1 %choose.left, i1 %early)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 60111 to ptr), i32 24, i1 false)
       to label %alloc.b.mixed unwind label %unwind.mixed
alloc.b.mixed:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 60112 to ptr), i32 24, i1 false)
       to label %choose.mixed unwind label %unwind.mixed
choose.mixed:
  br i1 %choose.left, label %left.mixed, label %right.mixed
left.mixed:
  %b.slot.mixed = getelementptr inbounds i8, ptr addrspace(1) %b, i64 16
  store atomic i32 41, ptr addrspace(1) %b.slot.mixed unordered, align 4
  br i1 %early, label %early.mixed, label %merge.mixed
right.mixed:
  br label %merge.mixed
merge.mixed:
  %pa = phi ptr addrspace(1) [ %a, %left.mixed ], [ null, %right.mixed ]
  %pb = phi ptr addrspace(1) [ %b, %left.mixed ], [ null, %right.mixed ]
  call void @sink(ptr addrspace(1) %pa)
  call void @sink(ptr addrspace(1) %pb)
  ret void
early.mixed:
  ret void
unwind.mixed:
  %lp.mixed = landingpad i64 cleanup
  resume i64 %lp.mixed
}

; MIXED-LABEL: define void @mixed_empty_and_nonempty_replay(
; MIXED: left.mixed:
; MIXED: br i1 %early, label %early.mixed, label %[[MIXED_EDGE:[-A-Za-z$._0-9]+]]
; MIXED: [[MIXED_EDGE]]:
; MIXED: store atomic i32 41, ptr addrspace(1) %{{[-A-Za-z$._0-9]+}} unordered, align 4
; MIXED-NEXT: br label %merge.mixed
; MIXED: merge.mixed:
; MIXED-NEXT: %pa = phi ptr addrspace(1) [ null, %right.mixed ], [ %a, %[[MIXED_EDGE]] ]
; MIXED-NEXT: %pb = phi ptr addrspace(1) [ null, %right.mixed ], [ %b, %[[MIXED_EDGE]] ]
; MIXED-NEXT: call void @sink(ptr addrspace(1) %pa)
; MIXED-NEXT: call void @sink(ptr addrspace(1) %pb)
; MIXED-NEXT: ret void
; MIXED: early.mixed:
; MIXED-NEXT: ret void

; Repeated switch successors are distinct CFG edges but one Source->Target
; replay plan. Splitting redirects both occurrences collectively and preserves
; the duplicate PHI inputs.
define void @duplicate_switch_edges(i1 %from.source, i2 %route,
                                    ptr addrspace(1) %guard)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %guard.lock = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 60201 to ptr), i32 16, i1 false)
       to label %choose unwind label %unwind.switch
choose:
  br i1 %from.source, label %source, label %right
source:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock)
  switch i2 %route, label %early.switch [
    i2 0, label %merge.switch
    i2 1, label %merge.switch
  ]
right:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %guard, ptr %guard.lock)
  br label %merge.switch
merge.switch:
  %r = phi ptr addrspace(1) [ %o, %source ], [ %o, %source ], [ null, %right ]
  %held = phi i1 [ true, %source ], [ true, %source ], [ false, %right ]
  call void @sink(ptr addrspace(1) %r)
  br i1 %held, label %source.exit, label %guard.exit
source.exit:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock)
  br label %done.switch
guard.exit:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %guard, ptr %guard.lock)
  br label %done.switch
early.switch:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock)
  br label %done.switch
done.switch:
  ret void
unwind.switch:
  %lp.switch = landingpad i64 cleanup
  resume i64 %lp.switch
}

; SWITCH-LABEL: define void @duplicate_switch_edges(
; SWITCH-LABEL: source:
; SWITCH: switch i2 %route, label %early.switch [
; SWITCH-NEXT: i2 0, label %[[SWITCH_EDGE:[-A-Za-z$._0-9]+]]
; SWITCH-NEXT: i2 1, label %[[SWITCH_EDGE]]
; SWITCH: [[SWITCH_EDGE]]:
; SWITCH: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %o, ptr %lock)
; SWITCH: br label %merge.switch

; Splitting an invoke unwind edge must use LLVM's landingpad-aware utility.
; The cloned landingpad remains the first non-PHI instruction, and replay is
; inserted after it but before its branch. A second virtual object with
; path-dependent fields forces a deferred field PHI at the same EH merge, so
; the test also covers PHI normalization performed by the split utility.
define void @unwind_landingpad_edge_replay(i2 %path)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock.one = alloca i64, align 8
  %lock.two = alloca i64, align 8
  %lock.three = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 60301 to ptr), i32 16, i1 false)
       to label %alloc.y unwind label %unwind.alloc
alloc.y:
  %y = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 60302 to ptr), i32 16, i1 false)
       to label %choose.eh unwind label %unwind.alloc
choose.eh:
  switch i2 %path, label %invoke.one [
    i2 1, label %invoke.two
    i2 2, label %invoke.three
  ]
invoke.one:
  %y.one = getelementptr inbounds i8, ptr addrspace(1) %y, i64 8
  store atomic i32 11, ptr addrspace(1) %y.one unordered, align 4
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock.one)
  invoke void @may_throw()
      to label %normal.one unwind label %handler
invoke.two:
  %y.two = getelementptr inbounds i8, ptr addrspace(1) %y, i64 8
  store atomic i32 22, ptr addrspace(1) %y.two unordered, align 4
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock.two)
  invoke void @may_throw()
      to label %normal.two unwind label %handler
invoke.three:
  %y.three = getelementptr inbounds i8, ptr addrspace(1) %y, i64 8
  store atomic i32 33, ptr addrspace(1) %y.three unordered, align 4
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock.three)
  invoke void @may_throw()
      to label %normal.three unwind label %handler
normal.one:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock.one)
  ret void
normal.two:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock.two)
  ret void
normal.three:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock.three)
  ret void
handler:
  %which.lock = phi ptr [ %lock.one, %invoke.one ], [ %lock.two, %invoke.two ], [ %lock.three, %invoke.three ]
  %lp.eh = landingpad i64 cleanup
  call void @sink(ptr addrspace(1) %o)
  call void @sink(ptr addrspace(1) %y)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %which.lock)
  resume i64 %lp.eh
unwind.alloc:
  %lp.alloc = landingpad i64 cleanup
  resume i64 %lp.alloc
}

; EH-LABEL: define void @unwind_landingpad_edge_replay(
; EH: invoke void @may_throw()
; EH-NEXT: to label %normal.one unwind label %[[EH_EDGE_ONE:[-A-Za-z$._0-9]+]]
; EH: invoke void @may_throw()
; EH-NEXT: to label %normal.two unwind label %[[EH_EDGE_TWO:[-A-Za-z$._0-9]+]]
; EH: invoke void @may_throw()
; EH-NEXT: to label %normal.three unwind label %[[EH_EDGE_THREE:[-A-Za-z$._0-9]+]]
; EH: [[EH_EDGE_THREE]]:
; EH-NEXT: %{{[-A-Za-z$._0-9]+}} = landingpad i64
; EH-NEXT: cleanup
; EH-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %o, ptr %lock.three)
; EH-NEXT: br label %[[EH_HANDLER:[-A-Za-z$._0-9]+]]
; EH: [[EH_EDGE_TWO]]:
; EH-NEXT: %{{[-A-Za-z$._0-9]+}} = landingpad i64
; EH-NEXT: cleanup
; EH-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %o, ptr %lock.two)
; EH-NEXT: br label %[[EH_JOIN_TWO:[-A-Za-z$._0-9]+]]
; EH: [[EH_EDGE_ONE]]:
; EH-NEXT: %{{[-A-Za-z$._0-9]+}} = landingpad i64
; EH-NEXT: cleanup
; EH-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %o, ptr %lock.one)
; EH-NEXT: br label %[[EH_JOIN_ONE:[-A-Za-z$._0-9]+]]
; EH: [[EH_JOIN_ONE]]:
; EH: br label %[[EH_JOIN_TWO]]
; EH: [[EH_JOIN_TWO]]:
; EH: %[[Y_ONE_TWO:[-A-Za-z$._0-9]+]] = phi i32 [ 22, %[[EH_EDGE_TWO]] ], [ 11, %[[EH_JOIN_ONE]] ]
; EH: br label %[[EH_HANDLER]]
; EH: [[EH_HANDLER]]:
; EH: %[[Y_ALL:[-A-Za-z$._0-9]+]] = phi i32 [ 33, %[[EH_EDGE_THREE]] ], [ %[[Y_ONE_TWO]], %[[EH_JOIN_TWO]] ]
; EH: store atomic i32 %[[Y_ALL]], ptr addrspace(1) %{{[-A-Za-z$._0-9]+}} unordered, align 4

!java-method-compilation = !{}
