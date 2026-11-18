; Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; RUN: opt -S -verify-each -passes='type-check-elimination,dce' -jeandle-vm-callback-log=%S/Inputs/load-klass-object-bounds.cblog %s | FileCheck %s
;
; Object bounds remain useful after Class.isAssignableFrom(getClass()) loses
; its mirror round trip. Klass loads alone do not prove their inputs nonnull.

declare hotspotcc ptr @jeandle.load_klass(ptr addrspace(1)) memory(read) nounwind willreturn
declare hotspotcc i1 @jeandle.check_klass_subtype(ptr, ptr) memory(read) nounwind willreturn
declare hotspotcc i1 @jeandle.check_klass_subtype_with_offset(ptr, ptr, i32) memory(read) nounwind willreturn
declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull) memory(read) nounwind willreturn
declare i32 @__gxx_personality_v0(...)

; CHECK-LABEL: @upper_bound(
; CHECK-NEXT: ret i1 true
define i1 @upper_bound(ptr addrspace(1) nonnull "java-klass"="200" %o) {
  %k = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %o)
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %k, ptr inttoptr (i64 200 to ptr))
  ret i1 %r
}

; CHECK-LABEL: @subtype_bound(
; CHECK-NEXT: ret i1 true
define i1 @subtype_bound(ptr addrspace(1) nonnull "java-klass"="210" %o) {
  %k = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %o)
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %k, ptr inttoptr (i64 200 to ptr))
  ret i1 %r
}

; CHECK-LABEL: @object_target(
; CHECK-NEXT: ret i1 true
define i1 @object_target(ptr addrspace(1) nonnull "java-klass"="100" %o) {
  %k = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %o)
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %k, ptr inttoptr (i64 100 to ptr))
  ret i1 %r
}

; CHECK-LABEL: @exact_miss(
; CHECK-NEXT: ret i1 false
define i1 @exact_miss(ptr addrspace(1) nonnull "java-klass"="200" "java-klass-exact" %o) {
  %k = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %o)
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %k, ptr inttoptr (i64 210 to ptr))
  ret i1 %r
}

; CHECK-LABEL: @incompatible_classes(
; CHECK-NEXT: ret i1 false
define i1 @incompatible_classes(ptr addrspace(1) nonnull "java-klass"="200" %o) {
  %k = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %o)
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %k, ptr inttoptr (i64 300 to ptr))
  ret i1 %r
}

; CHECK-LABEL: @offset_bound(
; CHECK-NEXT: ret i1 true
define i1 @offset_bound(ptr addrspace(1) nonnull "java-klass"="200" %o) {
  %k = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %o)
  %r = call hotspotcc i1 @jeandle.check_klass_subtype_with_offset(ptr %k, ptr inttoptr (i64 200 to ptr), i32 56)
  ret i1 %r
}

; CHECK-LABEL: @nullable_bound(
; CHECK: %r = call hotspotcc i1 @jeandle.check_klass_subtype
; CHECK-NEXT: ret i1 %r
define i1 @nullable_bound(ptr addrspace(1) "java-klass"="200" %o) {
  %k = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %o)
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %k, ptr inttoptr (i64 200 to ptr))
  ret i1 %r
}

; CHECK-LABEL: @possible_subclass(
; CHECK: %r = call hotspotcc i1 @jeandle.check_klass_subtype
; CHECK-NEXT: ret i1 %r
define i1 @possible_subclass(ptr addrspace(1) nonnull "java-klass"="200" %o) {
  %k = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %o)
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %k, ptr inttoptr (i64 210 to ptr))
  ret i1 %r
}

; CHECK-LABEL: @interface_overlap(
; CHECK: %r = call hotspotcc i1 @jeandle.check_klass_subtype
; CHECK-NEXT: ret i1 %r
define i1 @interface_overlap(ptr addrspace(1) nonnull "java-klass"="400" %o) {
  %k = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %o)
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %k, ptr inttoptr (i64 200 to ptr))
  ret i1 %r
}

; CHECK-LABEL: @dynamic_target(
; CHECK: %r = call hotspotcc i1 @jeandle.check_klass_subtype
; CHECK-NEXT: ret i1 %r
define i1 @dynamic_target(ptr addrspace(1) nonnull "java-klass"="200" %o, ptr %target) {
  %k = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %o)
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %k, ptr %target)
  ret i1 %r
}

; CHECK-LABEL: @wrong_load_cc(
; CHECK: %r = call hotspotcc i1 @jeandle.check_klass_subtype
; CHECK-NEXT: ret i1 %r
define i1 @wrong_load_cc(ptr addrspace(1) nonnull "java-klass"="200" %o) {
  %k = call ptr @jeandle.load_klass(ptr addrspace(1) %o)
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %k, ptr inttoptr (i64 200 to ptr))
  ret i1 %r
}

; CHECK-LABEL: @bundled_load(
; CHECK: %r = call hotspotcc i1 @jeandle.check_klass_subtype
; CHECK-NEXT: ret i1 %r
define i1 @bundled_load(ptr addrspace(1) nonnull "java-klass"="200" %o) {
  %k = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %o) [ "deopt"(i32 7) ]
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %k, ptr inttoptr (i64 200 to ptr))
  ret i1 %r
}

; CHECK-LABEL: @wrong_load_type(
; CHECK: %r = call hotspotcc i1 @jeandle.check_klass_subtype
; CHECK-NEXT: ret i1 %r
define i1 @wrong_load_type(ptr addrspace(1) nonnull "java-klass"="200" %o) {
  %k = call hotspotcc ptr (ptr addrspace(1), i32) @jeandle.load_klass(ptr addrspace(1) %o, i32 0)
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %k, ptr inttoptr (i64 200 to ptr))
  ret i1 %r
}

; CHECK-LABEL: @frozen_unknown(
; CHECK: %r = call hotspotcc i1 @jeandle.check_klass_subtype
; CHECK-NEXT: ret i1 %r
define i1 @frozen_unknown(ptr addrspace(1) nonnull "java-klass"="200" %o) {
  %f = freeze ptr addrspace(1) %o
  %k = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %f)
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %k, ptr inttoptr (i64 200 to ptr))
  ret i1 %r
}

; CHECK-LABEL: @nonnull_edge(
; CHECK: checked:
; CHECK-NEXT: ret i1 true
define i1 @nonnull_edge(ptr addrspace(1)  "java-klass"="200" %o, ptr addrspace(1) nonnull %other) {
entry:
  %guard = icmp ne ptr addrspace(1) %o, null
  br i1 %guard, label %checked, label %exit
checked:
  %k = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %o)
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %k, ptr inttoptr (i64 200 to ptr))
  ret i1 %r
exit:
  ret i1 false
}

; CHECK-LABEL: @interface_success(
; CHECK: checked:
; CHECK-NEXT: ret i1 true
define i1 @interface_success(ptr addrspace(1) nonnull  %o, ptr addrspace(1) nonnull %other) {
entry:
  %guard = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 400 to ptr), ptr addrspace(1) %o)
  br i1 %guard, label %checked, label %exit
checked:
  %k = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %o)
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %k, ptr inttoptr (i64 400 to ptr))
  ret i1 %r
exit:
  ret i1 false
}

; CHECK-LABEL: @excluded_subtype(
; CHECK: checked:
; CHECK-NEXT: ret i1 false
define i1 @excluded_subtype(ptr addrspace(1) nonnull  %o, ptr addrspace(1) nonnull %other) {
entry:
  %guard = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %o)
  br i1 %guard, label %exit, label %checked
checked:
  %k = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %o)
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %k, ptr inttoptr (i64 210 to ptr))
  ret i1 %r
exit:
  ret i1 false
}

; CHECK-LABEL: @other_object_guard(
; CHECK: checked:
; CHECK: %r = call hotspotcc i1 @jeandle.check_klass_subtype
; CHECK-NEXT: ret i1 %r
define i1 @other_object_guard(ptr addrspace(1) nonnull  %o, ptr addrspace(1) nonnull %other) {
entry:
  %guard = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 400 to ptr), ptr addrspace(1) %other)
  br i1 %guard, label %checked, label %exit
checked:
  %k = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %o)
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %k, ptr inttoptr (i64 400 to ptr))
  ret i1 %r
exit:
  ret i1 false
}

; The object is nonnull at the consumer, but not at its earlier Klass load.
; CHECK-LABEL: @late_null_guard(
; CHECK: checked:
; CHECK-NEXT: %r = call hotspotcc i1 @jeandle.check_klass_subtype
; CHECK-NEXT: ret i1 %r
define i1 @late_null_guard(ptr addrspace(1) "java-klass"="200" %o) {
entry:
  %k = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %o)
  %guard = icmp ne ptr addrspace(1) %o, null
  br i1 %guard, label %checked, label %exit
checked:
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %k, ptr inttoptr (i64 200 to ptr))
  ret i1 %r
exit:
  ret i1 false
}

; CHECK-LABEL: @invoked_load(
; CHECK: %k = invoke hotspotcc ptr @jeandle.load_klass
; CHECK: %r = call hotspotcc i1 @jeandle.check_klass_subtype
; CHECK-NEXT: ret i1 %r
define i1 @invoked_load(ptr addrspace(1) nonnull "java-klass"="200" %o) personality ptr @__gxx_personality_v0 {
entry:
  %k = invoke hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %o) to label %checked unwind label %unwind
checked:
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %k, ptr inttoptr (i64 200 to ptr))
  ret i1 %r
unwind:
  %lp = landingpad { ptr, i32 } cleanup
  resume { ptr, i32 } %lp
}

!java-method-compilation = !{}
