; RUN: opt -passes='loop-simplify,lcssa,jeandle-array-length-optimization,verify<loops>' -verify-each -S %s | FileCheck %s

declare i32 @jeandle.arraylength(ptr addrspace(1)) nounwind
declare void @effect(i32)
declare void @opaque(ptr addrspace(1))

; Availability crosses a cyclic region even when its source is outside it.
define i32 @cross_loop(ptr addrspace(1) noundef nonnull %a, i1 %c, i32 %n) {
; CHECK-LABEL: define i32 @cross_loop(
; CHECK: %l = call i32 @jeandle.arraylength
; CHECK: %r = call i32 @jeandle.arraylength
; CHECK: join:
; CHECK: %[[LENGTH:.*]] = phi i32
; CHECK-NOT: call i32 @jeandle.arraylength
; CHECK: ret i32 %[[LENGTH]]
entry:
  br i1 %c, label %left, label %right
left:
  %l = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  call void @effect(i32 %l)
  br label %join
right:
  br label %inner
inner:
  %i = phi i32 [ 0, %right ], [ %next, %inner ]
  %r = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  call void @effect(i32 %r)
  %next = add i32 %i, 1
  %more = icmp slt i32 %next, %n
  br i1 %more, label %inner, label %join
join:
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  ret i32 %again
}

; A source in an inner loop must leave both loops through LCSSA PHIs.
define i32 @nested_exits(ptr addrspace(1) noundef %a, i32 %n) {
; CHECK-LABEL: define i32 @nested_exits(
; CHECK: inner:
; CHECK: %first = call i32 @jeandle.arraylength
; CHECK: inner.exit:
; CHECK: %[[INNER:.*]] = phi i32 [ %first, %inner ]
; CHECK-NOT: call i32 @jeandle.arraylength
; CHECK: call void @effect(i32 %[[INNER]])
; CHECK: exit:
; CHECK: %[[OUTER:.*]] = phi i32 [ %[[INNER]], %inner.exit ]
; CHECK-NOT: call i32 @jeandle.arraylength
; CHECK: ret i32 %[[OUTER]]
entry:
  br label %outer
outer:
  %i = phi i32 [ 0, %entry ], [ %inext, %inner.exit ]
  br label %inner
inner:
  %j = phi i32 [ 0, %outer ], [ %jnext, %inner ]
  %first = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  call void @effect(i32 %first)
  %jnext = add i32 %j, 1
  %jmore = icmp slt i32 %jnext, %n
  br i1 %jmore, label %inner, label %inner.exit
inner.exit:
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  call void @effect(i32 %again)
  %inext = add i32 %i, 1
  %imore = icmp slt i32 %inext, %n
  br i1 %imore, label %outer, label %exit
exit:
  %final = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  ret i32 %final
}

; A source after an optional read does not establish availability at entry.
define i32 @missing_loop_path(ptr addrspace(1) noundef %a, i1 %read, i1 %more) {
; CHECK-LABEL: define i32 @missing_loop_path(
; CHECK: exit:
; CHECK-NOT: phi i32
; CHECK: %again = call i32 @jeandle.arraylength
entry:
  br label %loop
loop:
  br i1 %read, label %body, label %latch
body:
  %first = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  call void @effect(i32 %first)
  br label %latch
latch:
  br i1 %more, label %loop, label %exit
exit:
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  ret i32 %again
}

; A later iteration may select a different array without reading its length.
define i32 @changing_receiver(ptr addrspace(1) noundef %a, ptr addrspace(1) noundef %b, i1 %more) {
; CHECK-LABEL: define i32 @changing_receiver(
; CHECK: %first = call i32 @jeandle.arraylength
; CHECK: exit:
; CHECK: %again = call i32 @jeandle.arraylength
entry:
  %first = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  br label %loop
loop:
  %array = phi ptr addrspace(1) [ %a, %entry ], [ %b, %loop ]
  call void @opaque(ptr addrspace(1) %array)
  br i1 %more, label %loop, label %exit
exit:
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %array)
  ret i32 %again
}

; The selected length may itself originate inside another loop.
define i32 @loop_receiver_merge(ptr addrspace(1) noundef %a, ptr addrspace(1) noundef %b, i1 %which, i1 %more) {
; CHECK-LABEL: define i32 @loop_receiver_merge(
; CHECK: %la = call i32 @jeandle.arraylength
; CHECK: loop:
; CHECK: %lb = call i32 @jeandle.arraylength
; CHECK: loop.exit:
; CHECK: %[[EXIT:.*]] = phi i32 [ %lb, %loop ]
; CHECK: join:
; CHECK: %[[LENGTH:.*]] = phi i32
; CHECK-NOT: call i32 @jeandle.arraylength
; CHECK: ret i32 %[[LENGTH]]
entry:
  br i1 %which, label %left, label %right
left:
  %la = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  call void @effect(i32 %la)
  br label %join
right:
  br label %loop
loop:
  %lb = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %b)
  call void @effect(i32 %lb)
  br i1 %more, label %loop, label %loop.exit
loop.exit:
  call void @opaque(ptr addrspace(1) %b)
  br label %join
join:
  %array = phi ptr addrspace(1) [ %a, %left ], [ %b, %loop.exit ]
  call void @opaque(ptr addrspace(1) %array)
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %array)
  ret i32 %again
}

!java-method-compilation = !{}
