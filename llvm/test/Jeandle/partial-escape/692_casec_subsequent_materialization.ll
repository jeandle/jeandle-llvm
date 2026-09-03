; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s --check-prefix=IR
; RUN: opt -disable-output -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-dump-pea-stats -jeandle-pea-analyze-function=casec_live_escape \
; RUN:   %s 2>&1 | FileCheck %s --check-prefix=STATS
; RUN: opt -disable-output -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-dump-pea-stats -jeandle-pea-analyze-function=casec_live_child_state \
; RUN:   %s 2>&1 | FileCheck %s --check-prefix=CHILD-STATS
; RUN: opt -disable-output -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-dump-pea-stats -jeandle-pea-analyze-function=casec_different_virtual_children \
; RUN:   %s 2>&1 | FileCheck %s --check-prefix=DIFF-STATS
; RUN: opt -S -verify-each \
; RUN:   -passes="partial-escape-iterative,partial-escape-iterative" \
; RUN:   -jeandle-pea-iterations=8 %s | FileCheck %s --check-prefix=REPEAT

; A Case-C synthetic object has no allocation of its own.  When its identity
; becomes observable later, its real source allocations remain at their
; original sites, preserving their original deopt state.  Source field and
; monitor operations remain folded; the complete current synthetic state is
; replayed once onto the original Case-C PHI at the actual escape point.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1) nounwind
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare void @use_i32(i32)
declare void @safepoint()

define void @casec_live_escape(i1 %choose) gc "hotspotgc" {
entry:
  %lock = alloca i64, align 8
  br i1 %choose, label %left, label %right
left:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69201 to ptr), i32 24, i1 false) [ "deopt"(i32 692011) ]
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 7, ptr addrspace(1) %af unordered, align 4
  br label %merge
right:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69201 to ptr), i32 24, i1 false) [ "deopt"(i32 692012) ]
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 13, ptr addrspace(1) %bf unordered, align 4
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  %post = getelementptr inbounds i8, ptr addrspace(1) %p, i64 16
  store atomic i32 99, ptr addrspace(1) %post unordered, align 4
  %field = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  %v = load atomic i32, ptr addrspace(1) %field unordered, align 4
  call void @use_i32(i32 %v)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %p, ptr %lock)
  call void @sink(ptr addrspace(1) %p)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %p, ptr %lock)
  ret void
}

; The two original allocations are the only allocations.  Their source stores
; remain folded.  The merged field values and the post-merge store are replayed
; exactly once on %p, and the live monitor is re-emitted exactly once.
; IR-LABEL: define void @casec_live_escape(
; IR: left:
; IR-NOT: @jeandle.new_instance
; IR: %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; IR-NOT: store atomic
; IR-NEXT: br label %merge
; IR: right:
; IR-NOT: @jeandle.new_instance
; IR: %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; IR-NOT: store atomic
; IR-NEXT: br label %merge
; IR: merge:
; IR-NEXT: %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
; IR-NEXT: %[[FIELD:pea.casec.field.phi[^ ]*]] = phi i32 [ 7, %left ], [ 13, %right ]
; IR-NEXT: call void @use_i32(i32 %[[FIELD]])
; IR-NEXT: %[[SLOT8:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
; IR-NEXT: store atomic i32 %[[FIELD]], ptr addrspace(1) %[[SLOT8]] unordered, align 4
; IR-NEXT: %[[SLOT16:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %p, i64 16
; IR-NEXT: store atomic i32 99, ptr addrspace(1) %[[SLOT16]] unordered, align 4
; IR-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %p, ptr %lock)
; IR-NEXT: call void @sink(ptr addrspace(1) %p)
; IR-NEXT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %p, ptr %lock)
; IR-NOT: @jeandle.new_instance
; IR-NOT: store atomic
; IR-NOT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock
; IR-NOT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock
; IR-NOT: poison
; STATS: PEA stats @casec_live_escape: NeverEscapes=0 PartiallyEscapes=2 AlwaysEscapes=0

; Keeping the source allocation at its original site must not reintroduce its
; folded store onto either arm of a critical edge.  The one merged replay
; occurs only at the actual escape.
define void @casec_critical_edge(i1 %choose, i1 %take.merge)
    gc "hotspotgc" {
entry:
  br i1 %choose, label %left, label %right
left:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69202 to ptr), i32 16, i1 false) [ "deopt"(i32 692021) ]
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 21, ptr addrspace(1) %af unordered, align 4
  br i1 %take.merge, label %merge, label %bypass
right:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69202 to ptr), i32 16, i1 false) [ "deopt"(i32 692022) ]
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 22, ptr addrspace(1) %bf unordered, align 4
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  call void @sink(ptr addrspace(1) %p)
  ret void
bypass:
  ret void
}

; IR-LABEL: define void @casec_critical_edge(
; IR: left:
; IR-NOT: store atomic i32 21
; IR: br i1 %take.merge, label %merge, label %bypass
; IR: merge:
; IR-NEXT: %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
; IR-NEXT: %[[CFIELD:pea.casec.field.phi[^ ]*]] = phi i32 [ 21, %left ], [ 22, %right ]
; IR-NEXT: %[[CSLOT:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
; IR-NEXT: store atomic i32 %[[CFIELD]], ptr addrspace(1) %[[CSLOT]] unordered, align 4
; IR-NEXT: call void @sink(ptr addrspace(1) %p)
; IR-NOT: store atomic
; IR-NOT: call void @sink
; IR: bypass:
; IR-NEXT: ret void

; The source mapping is positional for arbitrary PHI fan-in, not a two-arm
; special case.
define void @casec_three_sources(i32 %which) gc "hotspotgc" {
entry:
  switch i32 %which, label %a0 [
    i32 1, label %a1
    i32 2, label %a2
  ]
a0:
  %o0 = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69203 to ptr), i32 16, i1 false) [ "deopt"(i32 692031) ]
  %f0 = getelementptr inbounds i8, ptr addrspace(1) %o0, i64 8
  store atomic i32 30, ptr addrspace(1) %f0 unordered, align 4
  br label %merge
a1:
  %o1 = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69203 to ptr), i32 16, i1 false) [ "deopt"(i32 692032) ]
  %f1 = getelementptr inbounds i8, ptr addrspace(1) %o1, i64 8
  store atomic i32 31, ptr addrspace(1) %f1 unordered, align 4
  br label %merge
a2:
  %o2 = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69203 to ptr), i32 16, i1 false) [ "deopt"(i32 692033) ]
  %f2 = getelementptr inbounds i8, ptr addrspace(1) %o2, i64 8
  store atomic i32 32, ptr addrspace(1) %f2 unordered, align 4
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %o0, %a0 ], [ %o1, %a1 ], [ %o2, %a2 ]
  call void @sink(ptr addrspace(1) %p)
  ret void
}

; IR-LABEL: define void @casec_three_sources(
; IR: a0:
; IR: %o0 = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; IR-NOT: store atomic
; IR-NEXT: br label %merge
; IR: a1:
; IR: %o1 = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; IR-NOT: store atomic
; IR-NEXT: br label %merge
; IR: a2:
; IR: %o2 = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; IR-NOT: store atomic
; IR-NEXT: br label %merge
; IR: merge:
; IR-NEXT: %p = phi ptr addrspace(1) [ %o0, %a0 ], [ %o1, %a1 ], [ %o2, %a2 ]
; IR-NEXT: %[[TFIELD:pea.casec.field.phi[^ ]*]] = phi i32 [ 30, %a0 ], [ 31, %a1 ], [ 32, %a2 ]
; IR-NEXT: %[[TSLOT:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
; IR-NEXT: store atomic i32 %[[TFIELD]], ptr addrspace(1) %[[TSLOT]] unordered, align 4
; IR-NEXT: call void @sink(ptr addrspace(1) %p)
; IR-NOT: store atomic
; IR-NOT: call void @sink
; IR-NOT: poison

; A downstream Case-B PHI still carries the prepared synthetic identity after
; point-local replay.  It must not be erased as though the synthetic were
; NeverEscapes.
define void @casec_then_caseb(i1 %source, i1 %route) gc "hotspotgc" {
entry:
  br i1 %source, label %left, label %right
left:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69204 to ptr), i32 16, i1 false) [ "deopt"(i32 692041) ]
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 61, ptr addrspace(1) %af unordered, align 4
  br label %casec
right:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69204 to ptr), i32 16, i1 false) [ "deopt"(i32 692042) ]
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 62, ptr addrspace(1) %bf unordered, align 4
  br label %casec
casec:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  br i1 %route, label %route.left, label %route.right
route.left:
  br label %caseb
route.right:
  br label %caseb
caseb:
  %q = phi ptr addrspace(1) [ %p, %route.left ], [ %p, %route.right ]
  call void @sink(ptr addrspace(1) %q)
  ret void
}

; IR-LABEL: define void @casec_then_caseb(
; IR: left:
; IR: %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; IR-NOT: store atomic
; IR-NEXT: br label %casec
; IR: right:
; IR: %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; IR-NOT: store atomic
; IR-NEXT: br label %casec
; IR: casec:
; IR-NEXT: %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
; IR-NEXT: %[[BFIELD:pea.casec.field.phi[^ ]*]] = phi i32 [ 61, %left ], [ 62, %right ]
; IR: caseb:
; IR-NOT: phi ptr addrspace(1)
; IR: %[[BSLOT:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
; IR-NEXT: store atomic i32 %[[BFIELD]], ptr addrspace(1) %[[BSLOT]] unordered, align 4
; IR-NEXT: call void @sink(ptr addrspace(1) %p)
; IR-NOT: store atomic
; IR-NOT: call void @sink
; IR-NOT: poison

; Recursive materialization uses the child's complete state at the owner's
; actual escape point.  The child allocation remains at its original site, but
; its folded scalar field is replayed immediately before the synthetic owner's
; folded reference field; no historical source store is resurrected.
define void @casec_live_child_state(i1 %choose) gc "hotspotgc" {
entry:
  %child = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69205 to ptr), i32 16, i1 false) [ "deopt"(i32 692051) ]
  %child.field = getelementptr inbounds i8, ptr addrspace(1) %child, i64 8
  store atomic i32 123, ptr addrspace(1) %child.field unordered, align 4
  br i1 %choose, label %left, label %right
left:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69206 to ptr), i32 24, i1 false) [ "deopt"(i32 692061) ]
  br label %merge
right:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69206 to ptr), i32 24, i1 false) [ "deopt"(i32 692062) ]
  br label %merge
merge:
  %owner = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  %owner.child = getelementptr inbounds i8, ptr addrspace(1) %owner, i64 16
  store atomic ptr addrspace(1) %child,
      ptr addrspace(1) %owner.child unordered, align 8
  call void @sink(ptr addrspace(1) %owner)
  ret void
}

; IR-LABEL: define void @casec_live_child_state(
; IR: %child = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 692051) ]
; IR-NOT: store atomic
; IR: %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 692061) ]
; IR-NOT: store atomic
; IR: %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 692062) ]
; IR-NOT: store atomic
; IR: merge:
; IR-NEXT: %owner = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
; IR-NEXT: %[[CHILD_SLOT:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %child, i64 8
; IR-NEXT: store atomic i32 123, ptr addrspace(1) %[[CHILD_SLOT]] unordered, align 4
; IR-NEXT: %[[OWNER_SLOT:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %owner, i64 16
; IR-NEXT: store atomic ptr addrspace(1) %child, ptr addrspace(1) %[[OWNER_SLOT]] unordered, align 8
; IR-NEXT: call void @sink(ptr addrspace(1) %owner)
; IR-NOT: store atomic
; IR-NOT: call void @sink
; IR-NOT: poison
; CHILD-STATS: PEA stats @casec_live_child_state: NeverEscapes=0 PartiallyEscapes=3 AlwaysEscapes=0

; If the two source owners contain different virtual children, the child
; identities must become real on their respective incoming paths before the
; owner field PHI is formed.  Each child gets exactly one scalar replay onto
; its own original allocation.  The synthetic owner then gets exactly one
; reference replay using the merged child identity.
define void @casec_different_virtual_children(i1 %choose) gc "hotspotgc" {
entry:
  br i1 %choose, label %left, label %right
left:
  %left.child = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69207 to ptr), i32 16, i1 false) [ "deopt"(i32 692071) ]
  %left.child.field = getelementptr inbounds i8,
      ptr addrspace(1) %left.child, i64 8
  store atomic i32 211, ptr addrspace(1) %left.child.field unordered, align 4
  %left.owner = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69208 to ptr), i32 24, i1 false) [ "deopt"(i32 692081) ]
  %left.owner.child = getelementptr inbounds i8,
      ptr addrspace(1) %left.owner, i64 16
  store atomic ptr addrspace(1) %left.child,
      ptr addrspace(1) %left.owner.child unordered, align 8
  br label %merge
right:
  %right.child = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69207 to ptr), i32 16, i1 false) [ "deopt"(i32 692072) ]
  %right.child.field = getelementptr inbounds i8,
      ptr addrspace(1) %right.child, i64 8
  store atomic i32 212, ptr addrspace(1) %right.child.field unordered, align 4
  %right.owner = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69208 to ptr), i32 24, i1 false) [ "deopt"(i32 692082) ]
  %right.owner.child = getelementptr inbounds i8,
      ptr addrspace(1) %right.owner, i64 16
  store atomic ptr addrspace(1) %right.child,
      ptr addrspace(1) %right.owner.child unordered, align 8
  br label %merge
merge:
  %owner = phi ptr addrspace(1) [ %left.owner, %left ],
                                  [ %right.owner, %right ]
  call void @sink(ptr addrspace(1) %owner)
  ret void
}

; IR-LABEL: define void @casec_different_virtual_children(
; IR: left:
; IR: %left.child = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 692071) ]
; IR-NOT: store atomic ptr
; IR: %left.owner = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 692081) ]
; IR-NOT: store atomic ptr
; IR: %[[LEFT_SLOT:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %left.child, i64 8
; IR-NEXT: store atomic i32 211, ptr addrspace(1) %[[LEFT_SLOT]] unordered, align 4
; IR-NEXT: br label %merge
; IR: right:
; IR: %right.child = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 692072) ]
; IR-NOT: store atomic ptr
; IR: %right.owner = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 692082) ]
; IR-NOT: store atomic ptr
; IR: %[[RIGHT_SLOT:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %right.child, i64 8
; IR-NEXT: store atomic i32 212, ptr addrspace(1) %[[RIGHT_SLOT]] unordered, align 4
; IR-NEXT: br label %merge
; IR: merge:
; IR-NEXT: %owner = phi ptr addrspace(1) [ %left.owner, %left ], [ %right.owner, %right ]
; IR-NEXT: %[[CHILD_PHI:pea.casec.field.phi[^ ]*]] = phi ptr addrspace(1) [ %left.child, %left ], [ %right.child, %right ]
; IR-NEXT: %[[MERGED_SLOT:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %owner, i64 16
; IR-NEXT: store atomic ptr addrspace(1) %[[CHILD_PHI]], ptr addrspace(1) %[[MERGED_SLOT]] unordered, align 8
; IR-NEXT: call void @sink(ptr addrspace(1) %owner)
; IR-NOT: store atomic
; IR-NOT: call void @sink
; IR-NOT: poison
; DIFF-STATS: PEA stats @casec_different_virtual_children: NeverEscapes=0 PartiallyEscapes=4 AlwaysEscapes=0

; A balanced synthetic monitor scope leaves no live lock to replay when the
; identity subsequently escapes.  Both monitor calls disappear, while the
; original source allocations and the sink remain exactly once.
define void @casec_balanced_monitor_then_escape(i1 %choose) gc "hotspotgc" {
entry:
  %lock = alloca i64, align 8
  br i1 %choose, label %left, label %right
left:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69209 to ptr), i32 16, i1 false) [ "deopt"(i32 692091) ]
  br label %merge
right:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69209 to ptr), i32 16, i1 false) [ "deopt"(i32 692092) ]
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %p, ptr %lock)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %p, ptr %lock)
  call void @sink(ptr addrspace(1) %p)
  ret void
}

; IR-LABEL: define void @casec_balanced_monitor_then_escape(
; IR: %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 692091) ]
; IR-NOT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock
; IR-NOT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock
; IR: %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 692092) ]
; IR-NOT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock
; IR-NOT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock
; IR: %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
; IR-NEXT: call void @sink(ptr addrspace(1) %p)
; IR-NOT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock
; IR-NOT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock
; IR-NOT: call void @sink
; IR-NOT: poison

; A deopt operand referencing a Case-C synthetic BEFORE its later ordinary
; escape: the synthetic is still virtual at the safepoint, so it is DESCRIBED
; there (VO descriptor + VORef slot) rather than materialized — a synthetic
; VO is treated identically to a normal VO in deopt.  The source allocations
; remain at their original sites because the synthetic later escapes at @sink;
; the complete then-current state is replayed onto %p once, at that escape
; point (not before the safepoint).
define void @casec_deopt_then_escape(i1 %choose) gc "hotspotgc" {
entry:
  br i1 %choose, label %left, label %right
left:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69210 to ptr), i32 24, i1 false) [ "deopt"(i32 692101) ]
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 301, ptr addrspace(1) %af unordered, align 4
  br label %merge
right:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69210 to ptr), i32 24, i1 false) [ "deopt"(i32 692102) ]
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 302, ptr addrspace(1) %bf unordered, align 4
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  %post = getelementptr inbounds i8, ptr addrspace(1) %p, i64 16
  store atomic i32 303, ptr addrspace(1) %post unordered, align 4
  call void @safepoint()
      [ "deopt"(i32 77, i32 77, i64 12, ptr addrspace(1) %p) ]
  store atomic i32 304, ptr addrspace(1) %post unordered, align 4
  call void @sink(ptr addrspace(1) %p)
  ret void
}

; IR-LABEL: define void @casec_deopt_then_escape(
; Sources stay real: the synthetic escapes at @sink, so its source allocations
; remain at their original sites.
; IR: %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 692101) ]
; IR: %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 692102) ]
; IR: %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
; IR: %[[DFIELD:pea.casec.field.phi[^ ]*]] = phi i32 [ 301, %left ], [ 302, %right ]
; The synthetic is VIRTUAL at the safepoint (it escapes only at @sink AFTER):
; no replay before the safepoint — it is DESCRIBED there.  Descriptor header
; (wire id 0, ScalarValueType, T_OBJECT) + klass 69210 + field_count 2; field
; offset 8 = merged PHI, field offset 16 = 303 (the value AT the safepoint);
; the %p slot is rewritten to a VORefLocalType reference (wire id 0).
; IR-NOT: pea.matslot
; IR-NOT: store atomic
; IR: call void @safepoint() [ "deopt"(
; IR-SAME: i32 77, i32 77,
; IR-SAME: i64 262156, i64 69210, i32 2,
; IR-SAME: i64 34359738378, i32 %[[DFIELD]],
; IR-SAME: i64 68719476746, i32 303,
; IR-SAME: i64 524300, i32 0) ]
; @sink escape: materialize ONCE here. offset 8 = merged PHI, offset 16 = 304
; (the value at the escape point).
; IR: %[[SLOT8:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
; IR: store atomic i32 %[[DFIELD]], ptr addrspace(1) %[[SLOT8]] unordered, align 4
; IR: %[[SLOT16:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %p, i64 16
; IR: store atomic i32 304, ptr addrspace(1) %[[SLOT16]] unordered, align 4
; IR: call void @sink(ptr addrspace(1) %p)
; IR-NOT: pea.matslot
; IR-NOT: store atomic
; IR-NOT: call void @safepoint
; IR-NOT: call void @sink
; IR-NOT: poison

; Re-running the complete iterative pass cannot duplicate an allocation,
; merged replay, post-merge access, or monitor operation.
; REPEAT-LABEL: define void @casec_live_escape(
; REPEAT-NOT: @jeandle.new_instance
; REPEAT: %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; REPEAT-NOT: @jeandle.new_instance
; REPEAT-NOT: store atomic i32
; REPEAT: %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; REPEAT-NOT: @jeandle.new_instance
; REPEAT-NOT: store atomic i32
; REPEAT: %[[RFIELD:pea.casec.field.phi[^ ]*]] = phi i32 [ 7, %left ], [ 13, %right ]
; REPEAT-NOT: store atomic i32
; REPEAT: store atomic i32 %[[RFIELD]]
; REPEAT-NEXT: %{{.*}} = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %p, i64 16
; REPEAT-NEXT: store atomic i32 99
; REPEAT-NOT: store atomic i32
; REPEAT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock
; REPEAT-NOT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock
; REPEAT: call void @sink
; REPEAT-NOT: call void @sink
; REPEAT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock
; REPEAT-NOT: @jeandle.new_instance
; REPEAT-NOT: store atomic i32
; REPEAT-NOT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock
; REPEAT-NOT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock
; REPEAT-NOT: call void @sink
; REPEAT-NOT: poison
; REPEAT-LABEL: define void @casec_critical_edge(

!java-method-compilation = !{}
