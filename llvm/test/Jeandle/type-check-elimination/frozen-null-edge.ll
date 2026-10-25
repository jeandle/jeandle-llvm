; RUN: opt -S -verify-each -passes=type-check-elimination -jeandle-vm-callback-log=%S/Inputs/frozen-null-edge.cblog %s | FileCheck %s

declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)

; A frozen poison value can contribute an unrelated non-null object.
define {ptr addrspace(1), i1} @keep_frozen_incoming(i1 noundef %pick, i1 %maybe_poison,
    ptr addrspace(1) noundef "java-klass"="3" %a) {
entry:
  %p = select i1 %maybe_poison, ptr addrspace(1) null, ptr addrspace(1) null
  %f = freeze ptr addrspace(1) %p
  br i1 %pick, label %left, label %right
left:
  br label %merge
right:
  br label %merge
merge:
  %obj = phi ptr addrspace(1) [ %a, %left ], [ %f, %right ]
  %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 3 to ptr), ptr addrspace(1) nonnull %obj)
  %p0 = insertvalue {ptr addrspace(1), i1} poison, ptr addrspace(1) %obj, 0
  %pair = insertvalue {ptr addrspace(1), i1} %p0, i1 %check, 1
  ret {ptr addrspace(1), i1} %pair
}
; CHECK-LABEL: @keep_frozen_incoming(
; CHECK: %check = call i1 @jeandle.check_instanceof
; CHECK: %pair = insertvalue {{.*}} i1 %check, 1

define i1 @skip_defined_null(i1 noundef %pick, i1 noundef %defined,
    ptr addrspace(1) noundef "java-klass"="3" %a) {
entry:
  %p = select i1 %defined, ptr addrspace(1) null, ptr addrspace(1) null
  %f = freeze ptr addrspace(1) %p
  br i1 %pick, label %left, label %right
left:
  br label %merge
right:
  br label %merge
merge:
  %obj = phi ptr addrspace(1) [ %a, %left ], [ %f, %right ]
  %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 3 to ptr), ptr addrspace(1) nonnull %obj)
  ret i1 %check
}
; CHECK-LABEL: @skip_defined_null(
; CHECK: ret i1 true

!java-method-compilation = !{}
