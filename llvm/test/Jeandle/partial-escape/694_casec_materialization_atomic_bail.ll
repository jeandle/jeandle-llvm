; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; Preparing a synthetic identity does not replay its source state on incoming
; edges.  Therefore even an indirectbr source is legal: both original
; allocation sites remain intact and the complete merged state is replayed
; once onto the Case-C PHI at the actual escape.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1) nounwind
declare void @sink(ptr addrspace(1))

define void @casec_atomic_unsplittable(i1 %choose, ptr %target)
    gc "hotspotgc" {
entry:
  br i1 %choose, label %right, label %left
right:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69401 to ptr), i32 16, i1 false) [ "deopt"(i32 694011) ]
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 82, ptr addrspace(1) %bf unordered, align 4
  br label %merge
left:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69401 to ptr), i32 16, i1 false) [ "deopt"(i32 694012) ]
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 81, ptr addrspace(1) %af unordered, align 4
  indirectbr ptr %target, [label %merge, label %bypass]
merge:
  %p = phi ptr addrspace(1) [ %b, %right ], [ %a, %left ]
  call void @sink(ptr addrspace(1) %p)
  ret void
bypass:
  ret void
}

; CHECK-LABEL: define void @casec_atomic_unsplittable(
; CHECK: right:
; CHECK-NEXT: %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 694011) ]
; CHECK-NOT: store atomic
; CHECK-NEXT: br label %merge
; CHECK: left:
; CHECK-NEXT: %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 694012) ]
; CHECK-NOT: store atomic
; CHECK-NEXT: indirectbr ptr %target, [label %merge, label %bypass]
; CHECK: merge:
; CHECK-NEXT: %p = phi ptr addrspace(1) [ %b, %right ], [ %a, %left ]
; CHECK-NEXT: %[[FIELD:pea.casec.field.phi[^ ]*]] = phi i32 [ 82, %right ], [ 81, %left ]
; CHECK-NEXT: %[[SLOT:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
; CHECK-NEXT: store atomic i32 %[[FIELD]], ptr addrspace(1) %[[SLOT]] unordered, align 4
; CHECK-NEXT: call void @sink(ptr addrspace(1) %p)
; CHECK-NOT: store atomic
; CHECK-NOT: call void @sink
; CHECK-NOT: poison

; A callbr is side-effecting and cannot be split by the transform.  Identity
; preparation is nevertheless safe because it does not place operations
; before or after the callbr edge.
define void @casec_atomic_callbr(i1 %choose) gc "hotspotgc" {
entry:
  br i1 %choose, label %right, label %left
right:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69402 to ptr), i32 16, i1 false) [ "deopt"(i32 694021) ]
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 92, ptr addrspace(1) %bf unordered, align 4
  br label %merge
left:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69402 to ptr), i32 16, i1 false) [ "deopt"(i32 694022) ]
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 91, ptr addrspace(1) %af unordered, align 4
  callbr void asm "", "!i"() to label %merge [label %bypass]
merge:
  %p = phi ptr addrspace(1) [ %b, %right ], [ %a, %left ]
  call void @sink(ptr addrspace(1) %p)
  ret void
bypass:
  ret void
}

; CHECK-LABEL: define void @casec_atomic_callbr(
; CHECK: right:
; CHECK-NEXT: %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 694021) ]
; CHECK-NOT: store atomic
; CHECK-NEXT: br label %merge
; CHECK: left:
; CHECK-NEXT: %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance{{.*}}[ "deopt"(i32 694022) ]
; CHECK-NOT: store atomic
; CHECK-NEXT: callbr void asm "", "!i"()
; CHECK-NEXT: to label %merge [label %bypass]
; CHECK: merge:
; CHECK-NEXT: %p = phi ptr addrspace(1) [ %b, %right ], [ %a, %left ]
; CHECK-NEXT: %[[CFIELD:pea.casec.field.phi[^ ]*]] = phi i32 [ 92, %right ], [ 91, %left ]
; CHECK-NEXT: %[[CSLOT:pea.matslot[^ ]*]] = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
; CHECK-NEXT: store atomic i32 %[[CFIELD]], ptr addrspace(1) %[[CSLOT]] unordered, align 4
; CHECK-NEXT: call void @sink(ptr addrspace(1) %p)
; CHECK-NOT: store atomic
; CHECK-NOT: call void @sink
; CHECK-NOT: poison

; Differing VirtualRef fields require eager child materialization on every
; incoming edge before the owner field PHI can be created.  The dynamic
; indirectbr edge cannot host that replay.  The complete Case-C candidate
; therefore stays real: neither the otherwise-safe right edge nor any child
; receives a partial pea.matslot plan, and all original stores survive.
define void @casec_different_child_unsplittable(i1 %choose, ptr %target)
    gc "hotspotgc" {
entry:
  br i1 %choose, label %right, label %left
right:
  %right.child = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69403 to ptr), i32 16, i1 false) [ "deopt"(i32 694031) ]
  %right.child.field = getelementptr inbounds i8,
      ptr addrspace(1) %right.child, i64 8
  store atomic i32 702,
      ptr addrspace(1) %right.child.field unordered, align 4
  %right.owner = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69404 to ptr), i32 24, i1 false) [ "deopt"(i32 694041) ]
  %right.owner.child = getelementptr inbounds i8,
      ptr addrspace(1) %right.owner, i64 16
  store atomic ptr addrspace(1) %right.child,
      ptr addrspace(1) %right.owner.child unordered, align 8
  br label %merge
left:
  %left.child = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69403 to ptr), i32 16, i1 false) [ "deopt"(i32 694032) ]
  %left.child.field = getelementptr inbounds i8,
      ptr addrspace(1) %left.child, i64 8
  store atomic i32 701,
      ptr addrspace(1) %left.child.field unordered, align 4
  %left.owner = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 69404 to ptr), i32 24, i1 false) [ "deopt"(i32 694042) ]
  %left.owner.child = getelementptr inbounds i8,
      ptr addrspace(1) %left.owner, i64 16
  store atomic ptr addrspace(1) %left.child,
      ptr addrspace(1) %left.owner.child unordered, align 8
  indirectbr ptr %target, [label %merge, label %bypass]
merge:
  %owner = phi ptr addrspace(1) [ %right.owner, %right ],
                                  [ %left.owner, %left ]
  call void @sink(ptr addrspace(1) %owner)
  ret void
bypass:
  ret void
}

; CHECK-LABEL: define void @casec_different_child_unsplittable(
; CHECK-NOT: pea.matslot
; CHECK: right:
; CHECK: %right.child = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: store atomic i32 702, ptr addrspace(1) %right.child.field unordered, align 4
; CHECK: %right.owner = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: store atomic ptr addrspace(1) %right.child, ptr addrspace(1) %right.owner.child unordered, align 8
; CHECK-NEXT: br label %merge
; CHECK-NOT: pea.matslot
; CHECK: left:
; CHECK: %left.child = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: store atomic i32 701, ptr addrspace(1) %left.child.field unordered, align 4
; CHECK: %left.owner = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: store atomic ptr addrspace(1) %left.child, ptr addrspace(1) %left.owner.child unordered, align 8
; CHECK-NEXT: indirectbr ptr %target, [label %merge, label %bypass]
; CHECK-NOT: pea.matslot
; CHECK: merge:
; CHECK-NEXT: %owner = phi ptr addrspace(1) [ %right.owner, %right ], [ %left.owner, %left ]
; CHECK-NEXT: call void @sink(ptr addrspace(1) %owner)
; CHECK-NOT: pea.matslot
; CHECK-NOT: poison

!java-method-compilation = !{}
