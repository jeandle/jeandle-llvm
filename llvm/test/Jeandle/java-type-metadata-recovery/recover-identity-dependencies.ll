; RUN: opt -S -verify-each -passes=recover-type-info -jeandle-vm-callback-log=%S/Inputs/recover-identity-dependencies.cblog %s -o %t.once
; RUN: FileCheck %s < %t.once
; RUN: opt -S -verify-each -passes='recover-type-info,recover-type-info' -jeandle-vm-callback-log=%S/Inputs/recover-identity-dependencies.cblog %s -o %t.twice
; RUN: diff -u %t.once %t.twice

@oop_handle_Root_0 = external global ptr addrspace(1)
declare ptr addrspace(1) @identity(ptr addrspace(1) returned)
declare ptr @raw_identity_fn(ptr returned)
declare ptr addrspace(1) @llvm.launder.invariant.group.p1(ptr addrspace(1))
declare ptr addrspace(1) @llvm.strip.invariant.group.p1(ptr addrspace(1))

define ptr addrspace(1) @returned_select(i1 %pick) #0 {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Root_0
  %child.addr = getelementptr i8, ptr addrspace(1) %base, i64 16
  %child = load ptr addrspace(1), ptr addrspace(1) %child.addr
  %id = call ptr addrspace(1) @identity(ptr addrspace(1) %child)
  %choose = select i1 %pick, ptr addrspace(1) %id, ptr addrspace(1) %child
  %grand.addr = getelementptr i8, ptr addrspace(1) %choose, i64 20
  %grand = load ptr addrspace(1), ptr addrspace(1) %grand.addr
  ret ptr addrspace(1) %grand
}
; CHECK-LABEL: @returned_select(
; CHECK: %child = load {{.*}}, !java-klass ![[CHILD:[0-9]+]]
; CHECK: %grand = load {{.*}}, !java-klass ![[GRAND:[0-9]+]], !java-klass-exact

define ptr addrspace(1) @constant_select(i1 %pick) #0 {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Root_0
  %child.addr = getelementptr i8, ptr addrspace(1) %base, i64 16
  %child = load ptr addrspace(1), ptr addrspace(1) %child.addr
  %choose = select i1 true, ptr addrspace(1) %child, ptr addrspace(1) undef
  %grand.addr = getelementptr i8, ptr addrspace(1) %choose, i64 20
  %grand = load ptr addrspace(1), ptr addrspace(1) %grand.addr
  ret ptr addrspace(1) %grand
}
; CHECK-LABEL: @constant_select(
; CHECK: %child = load {{.*}}, !java-klass ![[CHILD:[0-9]+]]
; CHECK: %grand = load {{.*}}, !java-klass ![[GRAND:[0-9]+]], !java-klass-exact

define ptr addrspace(1) @constant_false_select(i1 %pick) #0 {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Root_0
  %child.addr = getelementptr i8, ptr addrspace(1) %base, i64 16
  %child = load ptr addrspace(1), ptr addrspace(1) %child.addr
  %choose = select i1 false, ptr addrspace(1) undef, ptr addrspace(1) %child
  %grand.addr = getelementptr i8, ptr addrspace(1) %choose, i64 20
  %grand = load ptr addrspace(1), ptr addrspace(1) %grand.addr
  ret ptr addrspace(1) %grand
}
; CHECK-LABEL: @constant_false_select(
; CHECK: %child = load {{.*}}, !java-klass ![[CHILD:[0-9]+]]
; CHECK: %grand = load {{.*}}, !java-klass ![[GRAND:[0-9]+]], !java-klass-exact

define ptr addrspace(1) @returned_seed(i1 %pick) #0 {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Root_0
  %child.addr = getelementptr i8, ptr addrspace(1) %base, i64 16
  %child = load ptr addrspace(1), ptr addrspace(1) %child.addr
  %id = call "java-klass"="5" ptr addrspace(1) @identity(ptr addrspace(1) %child)
  %choose = select i1 %pick, ptr addrspace(1) %id, ptr addrspace(1) %child
  %grand.addr = getelementptr i8, ptr addrspace(1) %choose, i64 20
  %grand = load ptr addrspace(1), ptr addrspace(1) %grand.addr
  ret ptr addrspace(1) %grand
}
; CHECK-LABEL: @returned_seed(
; CHECK: %child = load {{.*}}, !java-klass ![[CHILD:[0-9]+]]
; CHECK: %grand = load {{.*}}, !java-klass ![[GRAND:[0-9]+]], !java-klass-exact

define ptr addrspace(1) @raw_identity(i1 %pick) #0 {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Root_0
  %child.addr = getelementptr i8, ptr addrspace(1) %base, i64 16
  %child = load ptr addrspace(1), ptr addrspace(1) %child.addr
  %raw = addrspacecast ptr addrspace(1) %child to ptr
  %id = call ptr @raw_identity_fn(ptr %raw)
  %wide = addrspacecast ptr %id to ptr addrspace(1)
  %choose = select i1 %pick, ptr addrspace(1) %wide, ptr addrspace(1) %child
  %grand.addr = getelementptr i8, ptr addrspace(1) %choose, i64 20
  %grand = load ptr addrspace(1), ptr addrspace(1) %grand.addr
  ret ptr addrspace(1) %grand
}
; CHECK-LABEL: @raw_identity(
; CHECK: %child = load {{.*}}, !java-klass ![[CHILD:[0-9]+]]
; CHECK: %grand = load {{.*}}, !java-klass ![[GRAND:[0-9]+]], !java-klass-exact

define ptr addrspace(1) @returned_cycle(i1 %pick) #0 {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Root_0
  %child.addr = getelementptr i8, ptr addrspace(1) %base, i64 16
  %child = load ptr addrspace(1), ptr addrspace(1) %child.addr
  br label %loop
loop:
  %p = phi ptr addrspace(1) [ %child, %entry ], [ %id, %loop ]
  %id = call "java-klass"="5" ptr addrspace(1) @identity(ptr addrspace(1) %p)
  br i1 %pick, label %loop, label %exit
exit:
  %choose = select i1 %pick, ptr addrspace(1) %id, ptr addrspace(1) %child
  %grand.addr = getelementptr i8, ptr addrspace(1) %choose, i64 20
  %grand = load ptr addrspace(1), ptr addrspace(1) %grand.addr
  ret ptr addrspace(1) %grand
}
; CHECK-LABEL: @returned_cycle(
; CHECK: %child = load {{.*}}, !java-klass ![[CHILD:[0-9]+]]
; CHECK: %grand = load {{.*}}, !java-klass ![[GRAND:[0-9]+]], !java-klass-exact

define ptr addrspace(1) @returned_own_seed(ptr addrspace(1) %opaque) #0 {
  %id = call "java-klass"="7" ptr addrspace(1) @identity(ptr addrspace(1) %opaque)
  %grand.addr = getelementptr i8, ptr addrspace(1) %id, i64 20
  %grand = load ptr addrspace(1), ptr addrspace(1) %grand.addr
  ret ptr addrspace(1) %grand
}
; CHECK-LABEL: @returned_own_seed(
; CHECK: %grand = load {{.*}}, !java-klass ![[GRAND]], !java-klass-exact

define ptr addrspace(1) @returned_late_init(i1 %pick) #0 {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Root_0
  br label %init
loop:
  %p = phi ptr addrspace(1) [ %child, %init ], [ %id, %loop ]
  %id = call "java-klass"="5" ptr addrspace(1) @identity(ptr addrspace(1) %p)
  br i1 %pick, label %loop, label %exit
init:
  %child.addr = getelementptr i8, ptr addrspace(1) %base, i64 16
  %child = load ptr addrspace(1), ptr addrspace(1) %child.addr
  br label %loop
exit:
  %grand.addr = getelementptr i8, ptr addrspace(1) %id, i64 20
  %grand = load ptr addrspace(1), ptr addrspace(1) %grand.addr
  ret ptr addrspace(1) %grand
}
; CHECK-LABEL: @returned_late_init(
; CHECK: %grand = load {{.*}}, !java-klass ![[GRAND]], !java-klass-exact

define ptr addrspace(1) @raw_returned_own_seed(ptr %opaque) #0 {
  %id = call "java-klass"="7" ptr @raw_identity_fn(ptr %opaque)
  %wide = addrspacecast ptr %id to ptr addrspace(1)
  %grand.addr = getelementptr i8, ptr addrspace(1) %wide, i64 20
  %grand = load ptr addrspace(1), ptr addrspace(1) %grand.addr
  ret ptr addrspace(1) %grand
}
; CHECK-LABEL: @raw_returned_own_seed(
; CHECK: %grand = load {{.*}}, !java-klass ![[GRAND]], !java-klass-exact

define ptr addrspace(1) @returned_field_address() #0 {
  %base = load ptr addrspace(1), ptr @oop_handle_Root_0
  %child.addr = getelementptr i8, ptr addrspace(1) %base, i64 16
  %child = load ptr addrspace(1), ptr addrspace(1) %child.addr
  %grand.addr = getelementptr i8, ptr addrspace(1) %child, i64 20
  %wrapped = call ptr addrspace(1) @identity(ptr addrspace(1) %grand.addr)
  %grand = load ptr addrspace(1), ptr addrspace(1) %wrapped
  ret ptr addrspace(1) %grand
}
; CHECK-LABEL: @returned_field_address(
; CHECK: %grand = load {{.*}}, !java-klass ![[GRAND]], !java-klass-exact

define ptr addrspace(1) @laundered_field_address() #0 {
  %base = load ptr addrspace(1), ptr @oop_handle_Root_0
  %child.addr = getelementptr i8, ptr addrspace(1) %base, i64 16
  %child = load ptr addrspace(1), ptr addrspace(1) %child.addr
  %grand.addr = getelementptr i8, ptr addrspace(1) %child, i64 20
  %wrapped = call ptr addrspace(1) @llvm.launder.invariant.group.p1(ptr addrspace(1) %grand.addr)
  %grand = load ptr addrspace(1), ptr addrspace(1) %wrapped
  ret ptr addrspace(1) %grand
}
; CHECK-LABEL: @laundered_field_address(
; CHECK: %grand = load {{.*}}, !java-klass ![[GRAND]], !java-klass-exact

define ptr addrspace(1) @stripped_field_address() #0 {
  %base = load ptr addrspace(1), ptr @oop_handle_Root_0
  %child.addr = getelementptr i8, ptr addrspace(1) %base, i64 16
  %child = load ptr addrspace(1), ptr addrspace(1) %child.addr
  %grand.addr = getelementptr i8, ptr addrspace(1) %child, i64 20
  %wrapped = call ptr addrspace(1) @llvm.strip.invariant.group.p1(ptr addrspace(1) %grand.addr)
  %grand = load ptr addrspace(1), ptr addrspace(1) %wrapped
  ret ptr addrspace(1) %grand
}
; CHECK-LABEL: @stripped_field_address(
; CHECK: %grand = load {{.*}}, !java-klass ![[GRAND]], !java-klass-exact

attributes #0 = { "java-method"="0" }
!java-method-compilation = !{}
; CHECK: ![[CHILD]] = !{i64 7}
; CHECK: ![[GRAND]] = !{i64 9}
