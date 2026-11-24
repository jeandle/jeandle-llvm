; RUN: opt -passes='function(jeandle-null-check-elimination)' -verify-each -S %s | FileCheck %s

; RUN: sed '/^!java-method-compilation/d' %s | opt -passes='function(jeandle-null-check-elimination)' -verify-each -S | FileCheck %s --check-prefix=NOJAVA

target datalayout = "e-p:64:64-p1:64:64-p3:32:32"
declare void @effect()

; The fast edge reuses the checked SSA reference; the slow edge loads a new one.
; Header PHIs consume both the joined pointer and a derived expression.
define ptr addrspace(3) @backedge(ptr addrspace(3) %first, ptr %slot, i1 %poll, i1 %done) {
; NOJAVA-LABEL: define ptr addrspace(3) @backedge(
; NOJAVA: fast:
; NOJAVA-NEXT: br label %join
; NOJAVA: %empty.next = icmp eq ptr addrspace(3) %joined, null
; CHECK-LABEL: define ptr addrspace(3) @backedge(
; CHECK: %p = phi ptr addrspace(3) {{.*}}[ %p, %[[SPLIT:fast.split[0-9]*]] ]
; CHECK: %n = phi i64 {{.*}}[ %inc{{[0-9]*}}, %[[SPLIT]] ]
; CHECK: fast:
; CHECK: br label %[[FAST:fast.split[0-9]*]]
; CHECK: [[FAST]]:
; CHECK-NOT: icmp
; CHECK: br label %header
; CHECK: slow:
; CHECK: %next = load
; CHECK: %joined = phi ptr addrspace(3) [ %next, %slow ]
; CHECK: icmp eq ptr addrspace(3) %joined, null
entry:
  %empty = icmp eq ptr addrspace(3) %first, null
  br i1 %empty, label %exit, label %header
header:
  %p = phi ptr addrspace(3) [ %first, %entry ], [ %joined, %join ]
  %n = phi i64 [ 0, %entry ], [ %inc, %join ]
  br i1 %done, label %exit, label %body
body:
  br i1 %poll, label %slow, label %fast
fast:
  br label %join
slow:
  call void @effect()
  %next = load ptr addrspace(3), ptr %slot
  br label %join
join:
  %joined = phi ptr addrspace(3) [ %p, %fast ], [ %next, %slow ]
  %inc = add i64 %n, 1
  %empty.next = icmp eq ptr addrspace(3) %joined, null
  br i1 %empty.next, label %exit, label %header
exit:
  %result = phi ptr addrspace(3) [ %first, %entry ], [ %p, %header ], [ %joined, %join ]
  ret ptr addrspace(3) %result
}

; Unknown input must not acquire a nonnull fact from the other incoming edge.
define i1 @unknown(ptr %p, ptr %q, i1 %which) {
; CHECK-LABEL: define i1 @unknown(
; CHECK: %joined = phi ptr
; CHECK: icmp ne ptr %joined, null
entry:
  br i1 %which, label %left, label %right
left:
  br label %join
right:
  br label %join
join:
  %joined = phi ptr [ %p, %left ], [ %q, %right ]
  %ok = icmp ne ptr %joined, null
  ret i1 %ok
}

define ptr @wide_swapped(ptr %first, ptr %slot, i1 %poll, i1 %done) {
; CHECK-LABEL: define ptr @wide_swapped(
; CHECK: fast:
; CHECK-NEXT: br label %fast.split
; CHECK: fast.split:
; CHECK-NOT: icmp
; CHECK: br label %header
; CHECK: icmp ne ptr null, %joined
entry:
  %empty = icmp ne ptr null, %first
  br i1 %empty, label %header, label %exit
header:
  %p = phi ptr [ %first, %entry ], [ %joined, %join ]
  %n = phi i64 [ 0, %entry ], [ %inc, %join ]
  br i1 %done, label %exit, label %body
body:
  br i1 %poll, label %slow, label %fast
fast:
  br label %join
slow:
  call void @effect()
  %next = load ptr, ptr %slot
  br label %join
join:
  %joined = phi ptr [ %p, %fast ], [ %next, %slow ]
  %inc = add i64 %n, 1
  %empty.next = icmp ne ptr null, %joined
  br i1 %empty.next, label %header, label %exit
exit:
  %result = phi ptr [ %first, %entry ], [ %p, %header ], [ %joined, %join ]
  ret ptr %result
}

define ptr addrspace(3) @fresh_fast(ptr addrspace(3) %first, ptr %slot, i1 %poll, i1 %done) {
; CHECK-LABEL: define ptr addrspace(3) @fresh_fast(
; CHECK: fast:
; CHECK-NOT: fast.split
; CHECK: br label %join
; CHECK: %empty.next = icmp eq ptr addrspace(3) %joined, null
entry:
  %empty = icmp eq ptr addrspace(3) %first, null
  br i1 %empty, label %exit, label %header
header:
  %p = phi ptr addrspace(3) [ %first, %entry ], [ %joined, %join ]
  %n = phi i64 [ 0, %entry ], [ %inc, %join ]
  br i1 %done, label %exit, label %body
body:
  br i1 %poll, label %slow, label %fast
fast:
  %fresh = load ptr addrspace(3), ptr %slot
  br label %join
slow:
  call void @effect()
  %next = load ptr addrspace(3), ptr %slot
  br label %join
join:
  %joined = phi ptr addrspace(3) [ %fresh, %fast ], [ %next, %slow ]
  %inc = add i64 %n, 1
  %empty.next = icmp eq ptr addrspace(3) %joined, null
  br i1 %empty.next, label %exit, label %header
exit:
  %result = phi ptr addrspace(3) [ %first, %entry ], [ %p, %header ], [ %joined, %join ]
  ret ptr addrspace(3) %result
}

define ptr addrspace(3) @freeze_fast(ptr addrspace(3) %first, ptr %slot, i1 %poll, i1 %done) {
; CHECK-LABEL: define ptr addrspace(3) @freeze_fast(
; CHECK: fast:
; CHECK-NOT: fast.split
; CHECK: br label %join
; CHECK: %empty.next = icmp eq ptr addrspace(3) %joined, null
entry:
  %empty = icmp eq ptr addrspace(3) %first, null
  br i1 %empty, label %exit, label %header
header:
  %p = phi ptr addrspace(3) [ %first, %entry ], [ %joined, %join ]
  %n = phi i64 [ 0, %entry ], [ %inc, %join ]
  br i1 %done, label %exit, label %body
body:
  br i1 %poll, label %slow, label %fast
fast:
  %frozen = freeze ptr addrspace(3) poison
  br label %join
slow:
  call void @effect()
  %next = load ptr addrspace(3), ptr %slot
  br label %join
join:
  %joined = phi ptr addrspace(3) [ %frozen, %fast ], [ %next, %slow ]
  %inc = add i64 %n, 1
  %empty.next = icmp eq ptr addrspace(3) %joined, null
  br i1 %empty.next, label %exit, label %header
exit:
  %result = phi ptr addrspace(3) [ %first, %entry ], [ %p, %header ], [ %joined, %join ]
  ret ptr addrspace(3) %result
}

define ptr addrspace(3) @null_fast(ptr addrspace(3) %first, ptr %slot, i1 %poll, i1 %done) {
; CHECK-LABEL: define ptr addrspace(3) @null_fast(
; CHECK: fast:
; CHECK-NOT: fast.split
; CHECK: br label %join
; CHECK: %empty.next = icmp eq ptr addrspace(3) %joined, null
entry:
  %empty = icmp eq ptr addrspace(3) %first, null
  br i1 %empty, label %exit, label %header
header:
  %p = phi ptr addrspace(3) [ %first, %entry ], [ %joined, %join ]
  %n = phi i64 [ 0, %entry ], [ %inc, %join ]
  br i1 %done, label %exit, label %body
body:
  br i1 %poll, label %slow, label %fast
fast:
  br label %join
slow:
  call void @effect()
  %next = load ptr addrspace(3), ptr %slot
  br label %join
join:
  %joined = phi ptr addrspace(3) [ null, %fast ], [ %next, %slow ]
  %inc = add i64 %n, 1
  %empty.next = icmp eq ptr addrspace(3) %joined, null
  br i1 %empty.next, label %exit, label %header
exit:
  %result = phi ptr addrspace(3) [ %first, %entry ], [ %p, %header ], [ %joined, %join ]
  ret ptr addrspace(3) %result
}

define ptr addrspace(3) @effectful_join(ptr addrspace(3) %first, ptr %slot, i1 %poll, i1 %done) {
; CHECK-LABEL: define ptr addrspace(3) @effectful_join(
; CHECK: fast:
; CHECK-NOT: fast.split
; CHECK: br label %join
; CHECK: %empty.next = icmp eq ptr addrspace(3) %joined, null
entry:
  %empty = icmp eq ptr addrspace(3) %first, null
  br i1 %empty, label %exit, label %header
header:
  %p = phi ptr addrspace(3) [ %first, %entry ], [ %joined, %join ]
  %n = phi i64 [ 0, %entry ], [ %inc, %join ]
  br i1 %done, label %exit, label %body
body:
  br i1 %poll, label %slow, label %fast
fast:
  br label %join
slow:
  call void @effect()
  %next = load ptr addrspace(3), ptr %slot
  br label %join
join:
  %joined = phi ptr addrspace(3) [ %p, %fast ], [ %next, %slow ]
  call void @effect()
  %inc = add i64 %n, 1
  %empty.next = icmp eq ptr addrspace(3) %joined, null
  br i1 %empty.next, label %exit, label %header
exit:
  %result = phi ptr addrspace(3) [ %first, %entry ], [ %p, %header ], [ %joined, %join ]
  ret ptr addrspace(3) %result
}

define ptr addrspace(3) @escaping_definition(ptr addrspace(3) %first, ptr %slot, i1 %poll, i1 %done) {
; CHECK-LABEL: define ptr addrspace(3) @escaping_definition(
; CHECK: fast:
; CHECK-NOT: fast.split
; CHECK: br label %join
; CHECK: %empty.next = icmp eq ptr addrspace(3) %joined, null
entry:
  %empty = icmp eq ptr addrspace(3) %first, null
  br i1 %empty, label %exit, label %header
header:
  %p = phi ptr addrspace(3) [ %first, %entry ], [ %joined, %join ]
  %n = phi i64 [ 0, %entry ], [ %inc, %join ]
  %escaped = ptrtoint ptr addrspace(3) %p to i64
  br i1 %done, label %exit, label %body
body:
  br i1 %poll, label %slow, label %fast
fast:
  br label %join
slow:
  call void @effect()
  %next = load ptr addrspace(3), ptr %slot
  br label %join
join:
  %joined = phi ptr addrspace(3) [ %p, %fast ], [ %next, %slow ]
  %inc = add i64 %n, 1
  %empty.next = icmp eq ptr addrspace(3) %joined, null
  br i1 %empty.next, label %escape, label %header
escape:
  %external = ptrtoint ptr addrspace(3) %joined to i64
  br label %exit
exit:
  %result = phi ptr addrspace(3) [ %first, %entry ], [ %p, %header ], [ %joined, %escape ]
  ret ptr addrspace(3) %result
}

define ptr addrspace(3) @two_fast_edges(ptr addrspace(3) %first, ptr %slot, i1 %poll, i1 %which, i1 %done) {
; CHECK-LABEL: define ptr addrspace(3) @two_fast_edges(
; CHECK: %p = phi ptr addrspace(3) {{.*}}[ %p, %fast.left.split ]{{.*}}[ %p, %fast.right.split ]
; CHECK: fast.left.split:
; CHECK-NOT: icmp
; CHECK: br label %header
; CHECK: fast.right.split:
; CHECK-NOT: icmp
; CHECK: br label %header
; CHECK: %joined = phi ptr addrspace(3) [ %next, %slow ]
entry:
  %empty = icmp eq ptr addrspace(3) %first, null
  br i1 %empty, label %exit, label %header
header:
  %p = phi ptr addrspace(3) [ %first, %entry ], [ %joined, %join ]
  %n = phi i64 [ 0, %entry ], [ %inc, %join ]
  br i1 %done, label %exit, label %body
body:
  br i1 %poll, label %slow, label %fast
fast:
  br i1 %which, label %fast.left, label %fast.right
fast.left:
  br label %join
fast.right:
  br label %join
slow:
  call void @effect()
  %next = load ptr addrspace(3), ptr %slot
  br label %join
join:
  %joined = phi ptr addrspace(3) [ %p, %fast.left ], [ %p, %fast.right ], [ %next, %slow ]
  %inc = add i64 %n, 1
  %empty.next = icmp eq ptr addrspace(3) %joined, null
  br i1 %empty.next, label %exit, label %header
exit:
  %result = phi ptr addrspace(3) [ %first, %entry ], [ %p, %header ], [ %joined, %join ]
  ret ptr addrspace(3) %result
}

!java-method-compilation = !{}

; Two plans can share an original edge: threading the header check first
; changes the success edge of the latch check. The second plan must be skipped.
define void @overlapping_checks(ptr %first, ptr %slot, i1 %which, i1 %done) {
; CHECK-LABEL: define void @overlapping_checks(
; CHECK: fast:
; CHECK-NEXT: br label %latch
; CHECK: latch:
; CHECK: br i1 %latch.empty, label %exit, label %latch.split
; CHECK: latch.split:
; CHECK-NOT: icmp
; CHECK: br label %body
entry:
  %empty = icmp eq ptr %first, null
  br i1 %empty, label %exit, label %header
header:
  %b = phi ptr [ %first, %entry ], [ %b, %latch ]
  %header.empty = icmp eq ptr %b, null
  br i1 %header.empty, label %exit, label %body
body:
  %c = phi ptr [ %b, %header ]
  br i1 %done, label %exit, label %choose
choose:
  br i1 %which, label %fast, label %slow
fast:
  br label %latch
slow:
  %next = load ptr, ptr %slot
  br label %latch
latch:
  %a = phi ptr [ %c, %fast ], [ %next, %slow ]
  %latch.empty = icmp eq ptr %a, null
  br i1 %latch.empty, label %exit, label %header
exit:
  ret void
}

; A branch condition used by successor PHIs needs its value on the threaded edge.
define i1 @condition_phi_eq(ptr %first, ptr %slot, i1 %poll, i32 %trips) {
; CHECK-LABEL: define i1 @condition_phi_eq(
; CHECK: %seen = phi i1 [ false, %entry ], [ %empty.next, %join ], [ false, %fast.split ]
; CHECK: fast.split:
; CHECK-NOT: icmp
; CHECK: br label %header
; CHECK: %empty.next = icmp eq ptr %joined, null
entry:
  %empty = icmp eq ptr %first, null
  br i1 %empty, label %exit, label %header
header:
  %p = phi ptr [ %first, %entry ], [ %joined, %join ]
  %n = phi i32 [ 0, %entry ], [ %inc, %join ]
  %seen = phi i1 [ false, %entry ], [ %empty.next, %join ]
  %done = icmp eq i32 %n, %trips
  br i1 %done, label %exit, label %body
body:
  br i1 %poll, label %slow, label %fast
fast:
  br label %join
slow:
  %next = load ptr, ptr %slot
  br label %join
join:
  %joined = phi ptr [ %p, %fast ], [ %next, %slow ]
  %inc = add i32 %n, 1
  %empty.next = icmp eq ptr %joined, null
  br i1 %empty.next, label %exit, label %header
exit:
  %result = phi i1 [ true, %entry ], [ %seen, %header ], [ %empty.next, %join ]
  ret i1 %result
}

define i1 @condition_phi_ne_swapped(ptr addrspace(3) %first, ptr %slot, i1 %poll, i32 %trips) {
; CHECK-LABEL: define i1 @condition_phi_ne_swapped(
; CHECK: %seen = phi i1 [ true, %entry ], [ %nonnull.next, %join ], [ true, %fast.split ]
; CHECK: fast.split:
; CHECK-NOT: icmp
; CHECK: br label %header
; CHECK: %nonnull.next = icmp ne ptr addrspace(3) null, %joined
entry:
  %empty = icmp eq ptr addrspace(3) %first, null
  br i1 %empty, label %exit, label %header
header:
  %p = phi ptr addrspace(3) [ %first, %entry ], [ %joined, %join ]
  %n = phi i32 [ 0, %entry ], [ %inc, %join ]
  %seen = phi i1 [ true, %entry ], [ %nonnull.next, %join ]
  %done = icmp eq i32 %n, %trips
  br i1 %done, label %exit, label %body
body:
  br i1 %poll, label %slow, label %fast
fast:
  br label %join
slow:
  %next = load ptr addrspace(3), ptr %slot
  br label %join
join:
  %joined = phi ptr addrspace(3) [ %p, %fast ], [ %next, %slow ]
  %inc = add i32 %n, 1
  %nonnull.next = icmp ne ptr addrspace(3) null, %joined
  br i1 %nonnull.next, label %header, label %exit
exit:
  %result = phi i1 [ false, %entry ], [ %seen, %header ], [ %nonnull.next, %join ]
  ret i1 %result
}
