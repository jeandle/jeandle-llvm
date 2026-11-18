; RUN: opt -S -verify-each -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/class-properties.cblog %s | FileCheck %s

@oop_handle_Mirror_0 = external global ptr addrspace(1)
@oop_handle_Mirror_1 = external global ptr addrspace(1)
@oop_handle_Mirror_2 = external global ptr addrspace(1)
@oop_handle_Mirror_3 = external global ptr addrspace(1)
@oop_handle_Mirror_4 = external global ptr addrspace(1)
@oop_handle_Mirror_5 = external global ptr addrspace(1)
@oop_handle_Mirror_6 = external global ptr addrspace(1)
@oop_handle_Mirror_7 = external global ptr addrspace(1)
declare hotspotcc i32 @jeandle.class_is_array(ptr addrspace(1))
declare hotspotcc i32 @jeandle.class_is_interface(ptr addrspace(1))
declare hotspotcc i32 @jeandle.class_is_primitive(ptr addrspace(1))
declare hotspotcc i32 @jeandle.class_is_hidden(ptr addrspace(1))
declare hotspotcc i32 @jeandle.class_get_modifiers(ptr addrspace(1))
declare hotspotcc i32 @jeandle.class_get_access_flags(ptr addrspace(1))

; CHECK-LABEL: @array(
; CHECK: ret i32 1
define i32 @array(i1 %c, ptr addrspace(1) %unknown) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_4
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_4
  %mirror = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %b
  %r = call hotspotcc i32 @jeandle.class_is_array(ptr addrspace(1) %mirror)
  ret i32 %r
}

; CHECK-LABEL: @nonarray(
; CHECK: ret i32 0
define i32 @nonarray(i1 %c, ptr addrspace(1) %unknown) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_1
  %mirror = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %b
  %r = call hotspotcc i32 @jeandle.class_is_array(ptr addrspace(1) %mirror)
  ret i32 %r
}

; CHECK-LABEL: @interface(
; CHECK: ret i32 1
define i32 @interface(i1 %c, ptr addrspace(1) %unknown) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_5
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_6
  br i1 %c, label %left, label %right
left:
  br label %join
right:
  br label %join
join:
  %mirror = phi ptr addrspace(1) [%a, %left], [%b, %right]
  %r = call hotspotcc i32 @jeandle.class_is_interface(ptr addrspace(1) %mirror)
  ret i32 %r
}

; CHECK-LABEL: @primitive(
; CHECK: ret i32 1
define i32 @primitive(i1 %c, ptr addrspace(1) %unknown) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_2
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_3
  %mirror = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %b
  %r = call hotspotcc i32 @jeandle.class_is_primitive(ptr addrspace(1) %mirror)
  ret i32 %r
}

; CHECK-LABEL: @hidden(
; CHECK: ret i32 1
define i32 @hidden(i1 %c, ptr addrspace(1) %unknown) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_7
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_7
  %mirror = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %b
  %r = call hotspotcc i32 @jeandle.class_is_hidden(ptr addrspace(1) %mirror)
  ret i32 %r
}

; CHECK-LABEL: @not_hidden(
; CHECK: ret i32 0
define i32 @not_hidden(i1 %c, ptr addrspace(1) %unknown) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_1
  br i1 %c, label %left, label %right
left:
  br label %join
right:
  br label %join
join:
  %mirror = phi ptr addrspace(1) [%a, %left], [%b, %right]
  %r = call hotspotcc i32 @jeandle.class_is_hidden(ptr addrspace(1) %mirror)
  ret i32 %r
}

; CHECK-LABEL: @modifiers(
; CHECK: ret i32 17
define i32 @modifiers(i1 %c, ptr addrspace(1) %unknown) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_1
  br i1 %c, label %left, label %right
left:
  br label %join
right:
  br label %join
join:
  %mirror = phi ptr addrspace(1) [%a, %left], [%b, %right]
  %r = call hotspotcc i32 @jeandle.class_get_modifiers(ptr addrspace(1) %mirror)
  ret i32 %r
}

; CHECK-LABEL: @primitive_modifiers(
; CHECK: ret i32 1041
define i32 @primitive_modifiers(i1 %c, ptr addrspace(1) %unknown) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_2
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_3
  %mirror = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %b
  %r = call hotspotcc i32 @jeandle.class_get_modifiers(ptr addrspace(1) %mirror)
  ret i32 %r
}

; CHECK-LABEL: @flags(
; CHECK: ret i32 49
define i32 @flags(i1 %c, ptr addrspace(1) %unknown) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_1
  %mirror = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %b
  %r = call hotspotcc i32 @jeandle.class_get_access_flags(ptr addrspace(1) %mirror)
  ret i32 %r
}

; CHECK-LABEL: @primitive_flags(
; CHECK: ret i32 1041
define i32 @primitive_flags(i1 %c, ptr addrspace(1) %unknown) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_2
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_3
  br i1 %c, label %left, label %right
left:
  br label %join
right:
  br label %join
join:
  %mirror = phi ptr addrspace(1) [%a, %left], [%b, %right]
  %r = call hotspotcc i32 @jeandle.class_get_access_flags(ptr addrspace(1) %mirror)
  ret i32 %r
}

; CHECK-LABEL: @conflict(
; CHECK: call hotspotcc i32 @jeandle.class_is_array
; CHECK: ret i32 %r
define i32 @conflict(i1 %c, ptr addrspace(1) %unknown) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_4
  %mirror = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %b
  %r = call hotspotcc i32 @jeandle.class_is_array(ptr addrspace(1) %mirror)
  ret i32 %r
}

; CHECK-LABEL: @unknown(
; CHECK: call hotspotcc i32 @jeandle.class_is_array
; CHECK: ret i32 %r
define i32 @unknown(i1 %c, ptr addrspace(1) %unknown) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %mirror = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %unknown
  %r = call hotspotcc i32 @jeandle.class_is_array(ptr addrspace(1) %mirror)
  ret i32 %r
}

; CHECK-LABEL: @defined_freeze(
; CHECK: ret i32 17
define i32 @defined_freeze(i1 noundef %c) {
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0, !noundef !0
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_1, !noundef !0
  %selected = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %b
  %mirror = freeze ptr addrspace(1) %selected
  %r = call hotspotcc i32 @jeandle.class_get_modifiers(ptr addrspace(1) %mirror)
  ret i32 %r
}

; CHECK-LABEL: @poison_freeze(
; CHECK: call hotspotcc i32 @jeandle.class_get_modifiers
define i32 @poison_freeze(i1 %c) {
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0, !noundef !0
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_1, !noundef !0
  %selected = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %b
  %mirror = freeze ptr addrspace(1) %selected
  %r = call hotspotcc i32 @jeandle.class_get_modifiers(ptr addrspace(1) %mirror)
  ret i32 %r
}

; CHECK-LABEL: @bundle(
; CHECK: call hotspotcc i32 @jeandle.class_get_modifiers
define hotspotcc i32 @bundle(ptr addrspace(1) %unused) {
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %r = call hotspotcc i32 @jeandle.class_get_modifiers(ptr addrspace(1) %a) [ "deopt"(i32 1) ]
  ret i32 %r
}

; CHECK-LABEL: @musttail(
; CHECK: call hotspotcc i32 @jeandle.class_get_modifiers
define hotspotcc i32 @musttail(ptr addrspace(1) %unused) {
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %r = musttail call hotspotcc i32 @jeandle.class_get_modifiers(ptr addrspace(1) %a)
  ret i32 %r
}

!java-method-compilation = !{}
!0 = !{}
