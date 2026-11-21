; RUN: opt -passes='jeandle-array-length-optimization' -verify-each -S %s | FileCheck %s
; RUN: opt -passes='loop-simplify,lcssa,jeandle-array-length-optimization' -verify-each -S %s | opt -passes='verify<loops>,verify<domtree>' -disable-output

declare i32 @jeandle.arraylength(ptr addrspace(1)) nounwind
declare void @opaque(ptr addrspace(1))

define i32 @diamond(ptr addrspace(1) noundef %a, ptr addrspace(1) noundef %b, i1 %c) {
; CHECK-LABEL: define i32 @diamond(
; CHECK: %left.length = call i32 @jeandle.arraylength
; CHECK: %right.length = call i32 @jeandle.arraylength
; CHECK: merge:
; CHECK-NEXT: %array.length = phi i32
; CHECK: call void @opaque
; CHECK-NOT: call i32 @jeandle.arraylength
; CHECK: ret i32 %array.length
entry:
  br i1 %c, label %left, label %right
left:
  %left.length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  call void @opaque(ptr addrspace(1) %a)
  br label %merge
right:
  %right.length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  br label %merge
merge:
  call void @opaque(ptr addrspace(1) %a)
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %again
}

define i32 @missing_path(ptr addrspace(1) noundef %a, ptr addrspace(1) noundef %b, i1 %c) {
; CHECK-LABEL: define i32 @missing_path(
; CHECK: merge:
; CHECK-NOT: phi i32
; CHECK: %again = call i32 @jeandle.arraylength
; CHECK: ret i32 %again
entry:
  br i1 %c, label %left, label %right
left:
  %left.length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  call void @opaque(ptr addrspace(1) %a)
  br label %merge
right:
  br label %merge
merge:
  call void @opaque(ptr addrspace(1) %a)
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %again
}

define i32 @different_array(ptr addrspace(1) noundef %a, ptr addrspace(1) noundef %b, i1 %c) {
; CHECK-LABEL: define i32 @different_array(
; CHECK: merge:
; CHECK-NOT: phi i32
; CHECK: %again = call i32 @jeandle.arraylength
; CHECK: ret i32 %again
entry:
  br i1 %c, label %left, label %right
left:
  %left.length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  call void @opaque(ptr addrspace(1) %a)
  br label %merge
right:
  %right.length = call i32 @jeandle.arraylength(ptr addrspace(1) %b)
  br label %merge
merge:
  call void @opaque(ptr addrspace(1) %a)
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %again
}

define i32 @undefined(ptr addrspace(1) %a, ptr addrspace(1) noundef %b, i1 %c) {
; CHECK-LABEL: define i32 @undefined(
; CHECK: merge:
; CHECK-NOT: phi i32
; CHECK: %again = call i32 @jeandle.arraylength
; CHECK: ret i32 %again
entry:
  br i1 %c, label %left, label %right
left:
  %left.length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  call void @opaque(ptr addrspace(1) %a)
  br label %merge
right:
  %right.length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  br label %merge
merge:
  call void @opaque(ptr addrspace(1) %a)
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %again
}

define i32 @freeze_identity(ptr addrspace(1) noundef %a, ptr addrspace(1) noundef %b, i1 %c) {
; CHECK-LABEL: define i32 @freeze_identity(
; CHECK: merge:
; CHECK-NOT: phi i32
; CHECK: %again = call i32 @jeandle.arraylength
; CHECK: ret i32 %again
entry:
  br i1 %c, label %left, label %right
left:
  %left.length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  call void @opaque(ptr addrspace(1) %a)
  br label %merge
right:
  %right.length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  br label %merge
merge:
  %frozen = freeze ptr addrspace(1) %b
  call void @opaque(ptr addrspace(1) %a)
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) %frozen)
  ret i32 %again
}

; The first iteration has no available length on the entry path.
define i32 @backedge_only(ptr addrspace(1) noundef %a, i1 %c) {
; CHECK-LABEL: define i32 @backedge_only(
; CHECK: loop:
; CHECK-NEXT: %again = call i32 @jeandle.arraylength
entry:
  br label %loop
loop:
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  br i1 %c, label %body, label %exit
body:
  call void @opaque(ptr addrspace(1) %a)
  %later = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  br label %loop
exit:
  ret i32 %again
}
!java-method-compilation = !{}
