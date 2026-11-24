; RUN: opt -passes='loop-simplify,lcssa,jeandle-affine-check-versioning' -verify-each -S %s | FileCheck %s

declare void @effect(i32)
define i32 @outer_addrec(i32 noundef %rows, i32 noundef %columns) {
; CHECK-LABEL: define i32 @outer_addrec(
; CHECK: inner.affine.check:
; CHECK: sext i32 %offset to i64
; CHECK: inner.affine.slow:
; CHECK: %ok.affine.slow = icmp ult
; CHECK: inner:
; CHECK: br i1 true, label %body, label %fail
entry:
  %positive = icmp sgt i32 %rows, 0
  br i1 %positive, label %outer.preheader, label %exit
outer.preheader:
  br label %outer
outer:
  %r = phi i32 [ 0, %outer.preheader ], [ %r.next, %outer.latch ]
  %offset = mul i32 %r, 7
  %enter = icmp sgt i32 %columns, 0
  br i1 %enter, label %inner.preheader, label %outer.latch
inner.preheader:
  br label %inner
inner:
  %j = phi i32 [ 0, %inner.preheader ], [ %j.next, %body ]
  %scaled = mul i32 %j, 3
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, 1024
  br i1 %ok, label %body, label %fail
body:
  call void @effect(i32 %index)
  %j.next = add i32 %j, 1
  %more = icmp slt i32 %j.next, %columns
  br i1 %more, label %inner, label %outer.latch
outer.latch:
  %r.next = add i32 %r, 1
  %again = icmp slt i32 %r.next, %rows
  br i1 %again, label %outer, label %exit
fail:
  ret i32 -1
exit:
  ret i32 0
}
define i32 @poison_outer_start(i32 noundef %rows, i32 noundef %columns) {
; CHECK-LABEL: define i32 @poison_outer_start(
; CHECK-NOT: affine.check
; CHECK: %ok = icmp ult
entry:
  %positive = icmp sgt i32 %rows, 0
  br i1 %positive, label %outer.preheader, label %exit
outer.preheader:
  br label %outer
outer:
  %r = phi i32 [ 0, %outer.preheader ], [ %r.next, %outer.latch ]
  %offset = mul nsw i32 %r, 7
  %enter = icmp sgt i32 %columns, 0
  br i1 %enter, label %inner.preheader, label %outer.latch
inner.preheader:
  br label %inner
inner:
  %j = phi i32 [ 0, %inner.preheader ], [ %j.next, %body ]
  %scaled = mul i32 %j, 3
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, 1024
  br i1 %ok, label %body, label %fail
body:
  call void @effect(i32 %index)
  %j.next = add i32 %j, 1
  %more = icmp slt i32 %j.next, %columns
  br i1 %more, label %inner, label %outer.latch
outer.latch:
  %r.next = add i32 %r, 1
  %again = icmp slt i32 %r.next, %rows
  br i1 %again, label %outer, label %exit
fail:
  ret i32 -1
exit:
  ret i32 0
}

define i32 @dynamic_outer_offset(i32 noundef %rows, i32 noundef %columns, i32 noundef %stride) {
; CHECK-LABEL: define i32 @dynamic_outer_offset(
; CHECK: inner.affine.check:
; CHECK: sext i32 %offset to i64
; CHECK: inner.affine.slow:
entry:
  %positive = icmp sgt i32 %rows, 0
  br i1 %positive, label %outer.preheader, label %exit
outer.preheader:
  br label %outer
outer:
  %r = phi i32 [ 0, %outer.preheader ], [ %r.next, %outer.latch ]
  %offset = mul i32 %r, %stride
  %enter = icmp sgt i32 %columns, 0
  br i1 %enter, label %inner.preheader, label %outer.latch
inner.preheader:
  br label %inner
inner:
  %j = phi i32 [ 0, %inner.preheader ], [ %j.next, %body ]
  %scaled = mul i32 %j, 3
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, 1024
  br i1 %ok, label %body, label %fail
body:
  call void @effect(i32 %index)
  %j.next = add i32 %j, 1
  %more = icmp slt i32 %j.next, %columns
  br i1 %more, label %inner, label %outer.latch
outer.latch:
  %r.next = add i32 %r, 1
  %again = icmp slt i32 %r.next, %rows
  br i1 %again, label %outer, label %exit
fail:
  ret i32 -1
exit:
  ret i32 0
}

define i32 @undef_outer_entry(i32 noundef %rows, i32 noundef %columns) {
; CHECK-LABEL: define i32 @undef_outer_entry(
; CHECK-NOT: affine.check
; CHECK: %ok = icmp ult
entry:
  %positive = icmp sgt i32 %rows, 0
  br i1 %positive, label %outer.preheader, label %exit
outer.preheader:
  br label %outer
outer:
  %r = phi i32 [ undef, %outer.preheader ], [ %r.next, %outer.latch ]
  %offset = mul i32 %r, 7
  %enter = icmp sgt i32 %columns, 0
  br i1 %enter, label %inner.preheader, label %outer.latch
inner.preheader:
  br label %inner
inner:
  %j = phi i32 [ 0, %inner.preheader ], [ %j.next, %body ]
  %scaled = mul i32 %j, 3
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, 1024
  br i1 %ok, label %body, label %fail
body:
  call void @effect(i32 %index)
  %j.next = add i32 %j, 1
  %more = icmp slt i32 %j.next, %columns
  br i1 %more, label %inner, label %outer.latch
outer.latch:
  %r.next = add i32 %r, 1
  %again = icmp slt i32 %r.next, %rows
  br i1 %again, label %outer, label %exit
fail:
  ret i32 -1
exit:
  ret i32 0
}

define i32 @poison_outer_entry(i32 noundef %rows, i32 noundef %columns) {
; CHECK-LABEL: define i32 @poison_outer_entry(
; CHECK-NOT: affine.check
; CHECK: %ok = icmp ult
entry:
  %positive = icmp sgt i32 %rows, 0
  br i1 %positive, label %outer.preheader, label %exit
outer.preheader:
  br label %outer
outer:
  %r = phi i32 [ poison, %outer.preheader ], [ %r.next, %outer.latch ]
  %offset = mul i32 %r, 7
  %enter = icmp sgt i32 %columns, 0
  br i1 %enter, label %inner.preheader, label %outer.latch
inner.preheader:
  br label %inner
inner:
  %j = phi i32 [ 0, %inner.preheader ], [ %j.next, %body ]
  %scaled = mul i32 %j, 3
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, 1024
  br i1 %ok, label %body, label %fail
body:
  call void @effect(i32 %index)
  %j.next = add i32 %j, 1
  %more = icmp slt i32 %j.next, %columns
  br i1 %more, label %inner, label %outer.latch
outer.latch:
  %r.next = add i32 %r, 1
  %again = icmp slt i32 %r.next, %rows
  br i1 %again, label %outer, label %exit
fail:
  ret i32 -1
exit:
  ret i32 0
}

define i32 @canonical_outer_increment(i32 noundef %rows, i32 noundef %columns) {
; CHECK-LABEL: define i32 @canonical_outer_increment(
; CHECK: inner.affine.check:
; CHECK: sext i32 %offset to i64
; CHECK: inner.affine.slow:
entry:
  %positive = icmp sgt i32 %rows, 0
  br i1 %positive, label %outer.preheader, label %exit
outer.preheader:
  br label %outer
outer:
  %r = phi i32 [ 0, %outer.preheader ], [ %r.next, %outer.latch ]
  %offset = mul i32 %r, 7
  %enter = icmp sgt i32 %columns, 0
  br i1 %enter, label %inner.preheader, label %outer.latch
inner.preheader:
  br label %inner
inner:
  %j = phi i32 [ 0, %inner.preheader ], [ %j.next, %body ]
  %scaled = mul i32 %j, 3
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, 1024
  br i1 %ok, label %body, label %fail
body:
  call void @effect(i32 %index)
  %j.next = add i32 %j, 1
  %more = icmp slt i32 %j.next, %columns
  br i1 %more, label %inner, label %outer.latch
outer.latch:
  %r.next = add nuw nsw i32 %r, 1
  %again = icmp slt i32 %r.next, %rows
  br i1 %again, label %outer, label %exit
fail:
  ret i32 -1
exit:
  ret i32 0
}

; Original has a defined execution: first outer iteration checks index 0;
; second returns 7 before consuming the poisoned offset.
define i32 @unrelated_edge(i32 noundef %columns) {
; CHECK-LABEL: define i32 @unrelated_edge(
; CHECK-NOT: affine.check
; CHECK: %ok = icmp ult
entry:
 br label %outer
outer:
 %r = phi i32 [ 2147483647, %entry ], [ %r.next, %outer.latch ]
 %count = phi i32 [ 0, %entry ], [ %count.next, %outer.latch ]
 %offset = sub i32 %r, 2147483647
 %enter = icmp sgt i32 %columns, 0
 br i1 %enter, label %preheader, label %outer.latch
preheader:
 br label %inner
inner:
 %j = phi i32 [ 0, %preheader ], [ %j.next, %body ]
 %skip = icmp sgt i32 %count, 0
 br i1 %skip, label %early, label %check
check:
 %scaled = mul i32 %j, 3
 %index = add i32 %offset, %scaled
 %ok = icmp ult i32 %index, 1024
 br i1 %ok, label %body, label %fail
body:
 %j.next = add i32 %j, 1
 %more = icmp slt i32 %j.next, %columns
 br i1 %more, label %inner, label %outer.latch
outer.latch:
 %r.next = add nsw i32 %r, 1
 %count.next = add i32 %count, 1
 %again = icmp slt i32 %count.next, 2
 br i1 %again, label %outer, label %exit
early:
 ret i32 7
fail:
 ret i32 -1
exit:
 ret i32 0
}
; Original has a defined execution: first outer iteration checks index 0;
; second returns 7 before consuming the poisoned offset.
define i32 @frozen_edge(i32 noundef %columns) {
; CHECK-LABEL: define i32 @frozen_edge(
; CHECK-NOT: affine.check
; CHECK: %ok = icmp ult
entry:
 br label %outer
outer:
 %r = phi i32 [ 2147483647, %entry ], [ %r.next, %outer.latch ]
 %count = phi i32 [ 0, %entry ], [ %count.next, %outer.latch ]
 %offset = sub i32 %r, 2147483647
 %enter = icmp sgt i32 %columns, 0
 br i1 %enter, label %preheader, label %outer.latch
preheader:
 br label %inner
inner:
 %j = phi i32 [ 0, %preheader ], [ %j.next, %body ]
 %skip = icmp sgt i32 %count, 0
 br i1 %skip, label %early, label %check
check:
 %scaled = mul i32 %j, 3
 %index = add i32 %offset, %scaled
 %ok = icmp ult i32 %index, 1024
 br i1 %ok, label %body, label %fail
body:
 %j.next = add i32 %j, 1
 %more = icmp slt i32 %j.next, %columns
 br i1 %more, label %inner, label %outer.latch
outer.latch:
 %r.next = add nsw i32 %r, 1
 %count.next = add i32 %count, 1
 %again.count = icmp slt i32 %count.next, 2
 %frozen = freeze i32 %r.next
 %guard = icmp eq i32 %frozen, 0
 %again = and i1 %again.count, %guard
 br i1 %again, label %outer, label %exit
early:
 ret i32 7
fail:
 ret i32 -1
exit:
 ret i32 0
}

!java-method-compilation = !{}
