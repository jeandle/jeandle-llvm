; RUN: opt -passes='jeandle-array-length-optimization' -verify-each -S %s | FileCheck %s

declare i32 @jeandle.arraylength(ptr addrspace(1)) nounwind
declare void @opaque(ptr addrspace(1))

; Array elements and unknown Java calls cannot change an array's length.
define i32 @cross_call(ptr addrspace(1) noundef %a) {
; CHECK-LABEL: define i32 @cross_call(
; CHECK: %first = call i32 @jeandle.arraylength
; CHECK: store atomic i32 12
; CHECK: call void @opaque
; CHECK-NOT: call i32 @jeandle.arraylength
; CHECK: %sum = add i32 %first, %first
  %first = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  %element = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i32 12, ptr addrspace(1) %element unordered, align 4
  call void @opaque(ptr addrspace(1) noundef %a)
  %second = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  %sum = add i32 %first, %second
  ret i32 %sum
}

define i32 @safe_hoist(ptr addrspace(1) noundef %a, i32 %n) {
; CHECK-LABEL: define i32 @safe_hoist(
; CHECK: preheader:
; CHECK-NEXT: %length = call i32 @jeandle.arraylength
; CHECK-NEXT: br label %loop
; CHECK: loop:
; CHECK-NOT: call i32 @jeandle.arraylength
; CHECK: ret i32
entry:
  %nonnull = icmp ne ptr addrspace(1) %a, null
  br i1 %nonnull, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %loop ]
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  call void @opaque(ptr addrspace(1) noundef %a)
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %n
  br i1 %again, label %loop, label %exit
exit:
  ret i32 0
}

; An unexecuted null array must never be read in the preheader.
define void @conditional_null(ptr addrspace(1) noundef %a, i32 %n, i1 %access) {
; CHECK-LABEL: define void @conditional_null(
; CHECK: entry:
; CHECK-NEXT: br label %loop
; CHECK: read:
; CHECK-NEXT: %length = call i32 @jeandle.arraylength
entry:
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %next, %latch ]
  br i1 %access, label %read, label %latch
read:
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  br label %latch
latch:
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %n
  br i1 %again, label %loop, label %exit
exit:
  ret void
}

define i32 @different_receivers(ptr addrspace(1) noundef %a, ptr addrspace(1) %b) {
; CHECK-LABEL: define i32 @different_receivers(
; CHECK: %first = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
; CHECK: %second = call i32 @jeandle.arraylength(ptr addrspace(1) %b)
  %first = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  %second = call i32 @jeandle.arraylength(ptr addrspace(1) %b)
  %sum = add i32 %first, %second
  ret i32 %sum
}

define i32 @merged_receiver(ptr addrspace(1) noundef %a, ptr addrspace(1) %b, i1 %c) {
; CHECK-LABEL: define i32 @merged_receiver(
; CHECK: %first = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
; CHECK: %second = call i32 @jeandle.arraylength(ptr addrspace(1) %merged)
  %first = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  %merged = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %b
  %second = call i32 @jeandle.arraylength(ptr addrspace(1) %merged)
  %sum = add i32 %first, %second
  ret i32 %sum
}

define i32 @interior_pointer(ptr addrspace(1) noundef %a) {
; CHECK-LABEL: define i32 @interior_pointer(
; CHECK: %first = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
; CHECK: %second = call i32 @jeandle.arraylength(ptr addrspace(1) %interior)
  %first = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  %interior = getelementptr i8, ptr addrspace(1) %a, i64 4
  %second = call i32 @jeandle.arraylength(ptr addrspace(1) %interior)
  %sum = add i32 %first, %second
  ret i32 %sum
}

define i32 @unproven_freeze(ptr addrspace(1) %a) {
; CHECK-LABEL: define i32 @unproven_freeze(
; CHECK: %first = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
; CHECK: %second = call i32 @jeandle.arraylength(ptr addrspace(1) %frozen)
  %first = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %frozen = freeze ptr addrspace(1) %a
  %second = call i32 @jeandle.arraylength(ptr addrspace(1) %frozen)
  %sum = add i32 %first, %second
  ret i32 %sum
}

; A use of undef may select a different array at each call.
define i32 @undefined_receiver(ptr addrspace(1) %a) {
; CHECK-LABEL: define i32 @undefined_receiver(
; CHECK: %first = call i32 @jeandle.arraylength
; CHECK: %second = call i32 @jeandle.arraylength
  %first = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %second = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %sum = add i32 %first, %second
  ret i32 %sum
}

; A null guard does not make an undef value stable for other uses.
define void @undefined_hoist(ptr addrspace(1) %a, i1 %access) {
; CHECK-LABEL: define void @undefined_hoist(
; CHECK: preheader:
; CHECK-NEXT: br label %loop
; CHECK: read:
; CHECK-NEXT: %length = call i32 @jeandle.arraylength
entry:
  %nonnull = icmp ne ptr addrspace(1) %a, null
  br i1 %nonnull, label %preheader, label %exit
preheader:
  br label %loop
loop:
  br i1 %access, label %read, label %exit
read:
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  br label %loop
exit:
  ret void
}

; A non-null address is not proof that an unexecuted read is safe.
define void @conditional_nonnull(ptr addrspace(1) noundef nonnull %a, i1 %access) {
; CHECK-LABEL: define void @conditional_nonnull(
; CHECK: entry:
; CHECK-NEXT: br label %loop
; CHECK: read:
; CHECK-NEXT: %length = call i32 @jeandle.arraylength
entry:
  br label %loop
loop:
  br i1 %access, label %read, label %exit
read:
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  br label %loop
exit:
  ret void
}

!java-method-compilation = !{}
