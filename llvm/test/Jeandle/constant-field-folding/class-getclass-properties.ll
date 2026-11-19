; Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; RUN: opt -S -verify-each -passes='constant-field-folding,mem2reg,constant-field-folding,instcombine,dce' -jeandle-vm-callback-log=%S/Inputs/class-getclass-properties.cblog %s | FileCheck %s

@AccessFlags.jvm_acc_is_hidden_class = constant i32 16777216
@AccessFlags.jvm_acc_written_flags = constant i32 32767
@java_lang_Object.klass = constant i64 100

declare hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1)) memory(read) nounwind willreturn
declare hotspotcc ptr @jeandle.load_klass(ptr addrspace(1)) memory(read) nounwind willreturn
declare hotspotcc i32 @jeandle.layout_helper(ptr) memory(read) nounwind willreturn
declare hotspotcc i32 @jeandle.klass_modifiers(ptr) memory(read) nounwind willreturn
declare hotspotcc i32 @jeandle.klass_access_flags(ptr, i32) memory(read) nounwind willreturn
declare hotspotcc ptr addrspace(1) @jeandle.klass_get_superclass(ptr) memory(read) nounwind willreturn
declare void @observe()
declare hotspotcc i32 @jeandle.class_is_array(ptr addrspace(1)) memory(read) nounwind willreturn
declare hotspotcc i32 @jeandle.class_is_hidden(ptr addrspace(1)) memory(read) nounwind willreturn
declare hotspotcc i32 @jeandle.class_get_modifiers(ptr addrspace(1)) memory(read) nounwind willreturn
declare hotspotcc i32 @jeandle.class_get_access_flags(ptr addrspace(1)) memory(read) nounwind willreturn
declare hotspotcc ptr addrspace(1) @jeandle.class_get_superclass(ptr addrspace(1)) memory(read) nounwind willreturn

; CHECK-LABEL: @array(
; CHECK-NOT: @jeandle.get_class
; CHECK: [[K:%.*]] = call hotspotcc ptr @jeandle.load_klass
; CHECK: call hotspotcc i32 @jeandle.layout_helper(ptr [[K]])
; CHECK: lshr i32 {{.*}}, 31
; CHECK-NOT: @jeandle.class_is_array
; CHECK: ret i32
define i32 @array(ptr addrspace(1) nonnull %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc i32 @jeandle.class_is_array(ptr addrspace(1) %m)
  ret i32 %r
}

; CHECK-LABEL: @hidden(
; CHECK-NOT: @jeandle.get_class
; CHECK: [[K:%.*]] = call hotspotcc ptr @jeandle.load_klass
; CHECK: call hotspotcc i32 @jeandle.klass_access_flags(ptr [[K]], i32 16777216)
; CHECK-NOT: @jeandle.class_is_hidden
; CHECK: ret i32
define i32 @hidden(ptr addrspace(1) nonnull %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc i32 @jeandle.class_is_hidden(ptr addrspace(1) %m)
  ret i32 %r
}

; CHECK-LABEL: @modifiers(
; CHECK-NOT: @jeandle.get_class
; CHECK: [[K:%.*]] = call hotspotcc ptr @jeandle.load_klass
; CHECK: call hotspotcc i32 @jeandle.klass_modifiers(ptr [[K]])
; CHECK-NOT: @jeandle.class_get_modifiers
; CHECK: ret i32
define i32 @modifiers(ptr addrspace(1) nonnull %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc i32 @jeandle.class_get_modifiers(ptr addrspace(1) %m)
  ret i32 %r
}

; CHECK-LABEL: @access(
; CHECK-NOT: @jeandle.get_class
; CHECK: [[K:%.*]] = call hotspotcc ptr @jeandle.load_klass
; CHECK: call hotspotcc i32 @jeandle.klass_access_flags(ptr [[K]], i32 32767)
; CHECK-NOT: @jeandle.class_get_access_flags
; CHECK: ret i32
define i32 @access(ptr addrspace(1) nonnull %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc i32 @jeandle.class_get_access_flags(ptr addrspace(1) %m)
  ret i32 %r
}

; CHECK-LABEL: @superclass(
; CHECK-NOT: @jeandle.get_class
; CHECK: [[K:%.*]] = call hotspotcc ptr @jeandle.load_klass
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.klass_get_superclass(ptr [[K]])
; CHECK-NOT: @jeandle.class_get_superclass
; CHECK: ret ptr addrspace(1)
define ptr addrspace(1) @superclass(ptr addrspace(1) nonnull %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass(ptr addrspace(1) %m)
  ret ptr addrspace(1) %r
}

; CHECK-LABEL: @number(
; CHECK-NOT: @jeandle.get_class
; CHECK-NOT: @jeandle.load_klass
; CHECK: ret i32 0
define i32 @number(ptr addrspace(1) nonnull "java-klass"="200" %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc i32 @jeandle.class_is_array(ptr addrspace(1) %m)
  ret i32 %r
}

; CHECK-LABEL: @object_array(
; CHECK-NOT: @jeandle.get_class
; CHECK-NOT: @jeandle.load_klass
; CHECK: ret i32 1
define i32 @object_array(ptr addrspace(1) nonnull "java-klass"="300" %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc i32 @jeandle.class_is_array(ptr addrspace(1) %m)
  ret i32 %r
}

; CHECK-LABEL: @object_bound(
; CHECK: call hotspotcc ptr @jeandle.load_klass
; CHECK: call hotspotcc i32 @jeandle.layout_helper
; CHECK: lshr i32 {{.*}}, 31
define i32 @object_bound(ptr addrspace(1) nonnull "java-klass"="100" %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc i32 @jeandle.class_is_array(ptr addrspace(1) %m)
  ret i32 %r
}

; CHECK-LABEL: @interface_bound(
; CHECK: call hotspotcc ptr @jeandle.load_klass
; CHECK: call hotspotcc i32 @jeandle.layout_helper
; CHECK: lshr i32 {{.*}}, 31
define i32 @interface_bound(ptr addrspace(1) nonnull "java-klass"="400" %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc i32 @jeandle.class_is_array(ptr addrspace(1) %m)
  ret i32 %r
}

; CHECK-LABEL: @nullable_number(
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.get_class
; CHECK: call hotspotcc i32 @jeandle.class_is_array
define i32 @nullable_number(ptr addrspace(1) "java-klass"="200" %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc i32 @jeandle.class_is_array(ptr addrspace(1) %m)
  ret i32 %r
}

; A live deopt use must retain the mirror even when the property uses Klass.
; CHECK-LABEL: @deopt_mirror(
; CHECK: [[M:%.*]] = call hotspotcc ptr addrspace(1) @jeandle.get_class
; CHECK: call hotspotcc i32 @jeandle.klass_modifiers
; CHECK: call void @observe() [ "deopt"(ptr addrspace(1) [[M]]) ]
define i32 @deopt_mirror(ptr addrspace(1) nonnull %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc i32 @jeandle.class_get_modifiers(ptr addrspace(1) %m)
  call void @observe() [ "deopt"(ptr addrspace(1) %m) ]
  ret i32 %r
}

; Distinct non-array bounds retain a common property through a mirror merge.
; CHECK-LABEL: @merged_bounds(
; CHECK: ret i32 0
define i32 @merged_bounds(i1 %c, ptr addrspace(1) nonnull "java-klass"="200" %a, ptr addrspace(1) nonnull "java-klass"="500" %b) {
  %ma = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %a)
  %mb = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %b)
  %m = select i1 %c, ptr addrspace(1) %ma, ptr addrspace(1) %mb
  %r = call hotspotcc i32 @jeandle.class_is_array(ptr addrspace(1) %m)
  ret i32 %r
}
; Exact origins must still reach constant-mirror superclass folding.
; CHECK-LABEL: @exact_superclass(
; CHECK-NOT: call
; CHECK: [[SUPER:%.*]] = load ptr addrspace(1), ptr @oop_handle_Mirror_8
; CHECK-NEXT: ret ptr addrspace(1) [[SUPER]]
define ptr addrspace(1) @exact_superclass(ptr addrspace(1) nonnull "java-klass"="500" "java-klass-exact" %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass(ptr addrspace(1) %m)
  ret ptr addrspace(1) %r
}
; This shape is exposed when PEA makes a previously dynamic Klass constant.
; CHECK-LABEL: @late_constant_superclass(
; CHECK-NOT: call
; CHECK: [[SUPER:%.*]] = load ptr addrspace(1), ptr @oop_handle_Mirror_8
; CHECK-NEXT: ret ptr addrspace(1) [[SUPER]]
define ptr addrspace(1) @late_constant_superclass() {
  %r = call hotspotcc ptr addrspace(1) @jeandle.klass_get_superclass(ptr inttoptr (i64 500 to ptr))
  ret ptr addrspace(1) %r
}
; A preceding query rewrite must not hide exact facts exposed by forwarding.
; CHECK-LABEL: @forwarded_exact_superclass(
; CHECK-NOT: call
; CHECK: [[SUPER:%.*]] = load ptr addrspace(1), ptr @oop_handle_Mirror_8
; CHECK-NEXT: ret ptr addrspace(1) [[SUPER]]
define ptr addrspace(1) @forwarded_exact_superclass(ptr addrspace(1) nonnull "java-klass"="500" "java-klass-exact" %known) {
  %slot = alloca ptr addrspace(1)
  store ptr addrspace(1) %known, ptr %slot
  %obj = load ptr addrspace(1), ptr %slot, !nonnull !0
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass(ptr addrspace(1) %m)
  ret ptr addrspace(1) %r
}

; A non-exact array bound proves Java superclass and hidden status, including
; primitive/multidimensional arrays. Modifier visibility still depends on the
; component, so it must not be inferred from array-ness alone.
; CHECK-LABEL: @array_superclass(
; CHECK-NOT: call
; CHECK: [[SUPER:%.*]] = load ptr addrspace(1), ptr @oop_handle_Mirror_8
; CHECK-NEXT: ret ptr addrspace(1) [[SUPER]]
define ptr addrspace(1) @array_superclass(ptr addrspace(1) nonnull "java-klass"="300" %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass(ptr addrspace(1) %m)
  ret ptr addrspace(1) %r
}

; CHECK-LABEL: @primitive_array_superclass(
; CHECK-NOT: call
; CHECK: [[SUPER:%.*]] = load ptr addrspace(1), ptr @oop_handle_Mirror_8
; CHECK-NEXT: ret ptr addrspace(1) [[SUPER]]
define ptr addrspace(1) @primitive_array_superclass(ptr addrspace(1) nonnull "java-klass"="600" %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass(ptr addrspace(1) %m)
  ret ptr addrspace(1) %r
}

; CHECK-LABEL: @multi_array_superclass(
; CHECK-NOT: call
; CHECK: [[SUPER:%.*]] = load ptr addrspace(1), ptr @oop_handle_Mirror_8
; CHECK-NEXT: ret ptr addrspace(1) [[SUPER]]
define ptr addrspace(1) @multi_array_superclass(ptr addrspace(1) nonnull "java-klass"="700" %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass(ptr addrspace(1) %m)
  ret ptr addrspace(1) %r
}

; CHECK-LABEL: @array_hidden(
; CHECK-NOT: call
; CHECK-NEXT: ret i32 0
define i32 @array_hidden(ptr addrspace(1) nonnull "java-klass"="300" %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc i32 @jeandle.class_is_hidden(ptr addrspace(1) %m)
  ret i32 %r
}

; CHECK-LABEL: @merged_array_superclass(
; CHECK-NOT: call
; CHECK: [[SUPER:%.*]] = load ptr addrspace(1), ptr @oop_handle_Mirror_8
; CHECK-NEXT: ret ptr addrspace(1) [[SUPER]]
define ptr addrspace(1) @merged_array_superclass(i1 %c, ptr addrspace(1) nonnull "java-klass"="300" %a, ptr addrspace(1) nonnull "java-klass"="600" %b) {
  %ma = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %a)
  %mb = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %b)
  %m = select i1 %c, ptr addrspace(1) %ma, ptr addrspace(1) %mb
  %r = call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass(ptr addrspace(1) %m)
  ret ptr addrspace(1) %r
}

; Folding a query must not erase the original mirror needed for deoptimization.
; CHECK-LABEL: @array_superclass_deopt(
; CHECK: [[M:%.*]] = call hotspotcc ptr addrspace(1) @jeandle.get_class
; CHECK: [[SUPER:%.*]] = load ptr addrspace(1), ptr @oop_handle_Mirror_8
; CHECK: call void @observe() [ "deopt"(ptr addrspace(1) [[M]]) ]
; CHECK-NEXT: ret ptr addrspace(1) [[SUPER]]
define ptr addrspace(1) @array_superclass_deopt(ptr addrspace(1) nonnull "java-klass"="300" %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass(ptr addrspace(1) %m)
  call void @observe() [ "deopt"(ptr addrspace(1) %m) ]
  ret ptr addrspace(1) %r
}

; CHECK-LABEL: @nullable_array_superclass(
; CHECK: %m = call hotspotcc ptr addrspace(1) @jeandle.get_class
; CHECK: %r = call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass
; CHECK-NEXT: ret ptr addrspace(1) %r
define ptr addrspace(1) @nullable_array_superclass(ptr addrspace(1) "java-klass"="300" %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass(ptr addrspace(1) %m)
  ret ptr addrspace(1) %r
}

; CHECK-LABEL: @object_superclass(
; CHECK: call hotspotcc ptr @jeandle.load_klass
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.klass_get_superclass
; CHECK: ret ptr addrspace(1)
define ptr addrspace(1) @object_superclass(ptr addrspace(1) nonnull "java-klass"="100" %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass(ptr addrspace(1) %m)
  ret ptr addrspace(1) %r
}

; CHECK-LABEL: @interface_superclass(
; CHECK: call hotspotcc ptr @jeandle.load_klass
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.klass_get_superclass
; CHECK: ret ptr addrspace(1)
define ptr addrspace(1) @interface_superclass(ptr addrspace(1) nonnull "java-klass"="400" %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass(ptr addrspace(1) %m)
  ret ptr addrspace(1) %r
}

; CHECK-LABEL: @array_modifiers(
; CHECK: call hotspotcc ptr @jeandle.load_klass
; CHECK: call hotspotcc i32 @jeandle.klass_modifiers
; CHECK: ret i32
define i32 @array_modifiers(ptr addrspace(1) nonnull "java-klass"="300" %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc i32 @jeandle.class_get_modifiers(ptr addrspace(1) %m)
  ret i32 %r
}

; CHECK-LABEL: @array_access_flags(
; CHECK: call hotspotcc ptr @jeandle.load_klass
; CHECK: call hotspotcc i32 @jeandle.klass_access_flags
; CHECK: ret i32
define i32 @array_access_flags(ptr addrspace(1) nonnull "java-klass"="300" %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc i32 @jeandle.class_get_access_flags(ptr addrspace(1) %m)
  ret i32 %r
}

; CHECK-LABEL: @unavailable_array_mirror(
; CHECK: call hotspotcc ptr @jeandle.load_klass
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.klass_get_superclass
; CHECK: ret ptr addrspace(1)
define ptr addrspace(1) @unavailable_array_mirror(ptr addrspace(1) nonnull "java-klass"="800" %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass(ptr addrspace(1) %m)
  ret ptr addrspace(1) %r
}

; CHECK-LABEL: @unavailable_array_superclass(
; CHECK: call hotspotcc ptr @jeandle.load_klass
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.klass_get_superclass
; CHECK: ret ptr addrspace(1)
define ptr addrspace(1) @unavailable_array_superclass(ptr addrspace(1) nonnull "java-klass"="900" %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass(ptr addrspace(1) %m)
  ret ptr addrspace(1) %r
}

; CHECK-LABEL: @unavailable_superclass_mirror(
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.{{(class|klass)_get_superclass}}
; CHECK: ret ptr addrspace(1)
define ptr addrspace(1) @unavailable_superclass_mirror(ptr addrspace(1) nonnull "java-klass"="1000" %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass(ptr addrspace(1) %m)
  ret ptr addrspace(1) %r
}

!java-method-compilation = !{}
!0 = !{}
