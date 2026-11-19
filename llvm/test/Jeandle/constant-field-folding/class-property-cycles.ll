; Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
;
; Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM Exceptions.
; See https://llvm.org/LICENSE.txt for license information.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; RUN: opt -S -verify-each -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/class-properties.cblog %s | FileCheck %s

@oop_handle_Mirror_0 = external global ptr addrspace(1)
@oop_handle_Mirror_1 = external global ptr addrspace(1)
@oop_handle_Mirror_2 = external global ptr addrspace(1)
declare hotspotcc i32 @jeandle.class_is_primitive(ptr addrspace(1))
declare hotspotcc i32 @jeandle.class_is_interface(ptr addrspace(1))

; CHECK-LABEL: @loop_same_property(
; CHECK-NOT: call hotspotcc i32 @jeandle.class_is_primitive
; CHECK: ret i32 0
define i32 @loop_same_property(i1 %again, i1 %choose) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_1
  br label %loop
loop:
  %m = phi ptr addrspace(1) [%a, %entry], [%next, %loop]
  %next = select i1 %choose, ptr addrspace(1) %m, ptr addrspace(1) %b
  %r = call hotspotcc i32 @jeandle.class_is_primitive(ptr addrspace(1) %m)
  br i1 %again, label %loop, label %exit
exit:
  ret i32 %r
}

; CHECK-LABEL: @mutual_phis(
; CHECK-NOT: call hotspotcc i32 @jeandle.class_is_interface
; CHECK: ret i32 0
define i32 @mutual_phis(i1 %again) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_1
  br label %loop
loop:
  %x = phi ptr addrspace(1) [%a, %entry], [%y, %loop]
  %y = phi ptr addrspace(1) [%b, %entry], [%x, %loop]
  %r = call hotspotcc i32 @jeandle.class_is_interface(ptr addrspace(1) %x)
  br i1 %again, label %loop, label %exit
exit:
  ret i32 %r
}

; CHECK-LABEL: @conflicting_cycle(
; CHECK: %r = call hotspotcc i32 @jeandle.class_is_primitive
; CHECK: ret i32 %r
define i32 @conflicting_cycle(i1 %again, i1 %choose) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_2
  br label %loop
loop:
  %m = phi ptr addrspace(1) [%a, %entry], [%next, %loop]
  %next = select i1 %choose, ptr addrspace(1) %m, ptr addrspace(1) %b
  %r = call hotspotcc i32 @jeandle.class_is_primitive(ptr addrspace(1) %m)
  br i1 %again, label %loop, label %exit
exit:
  ret i32 %r
}

; CHECK-LABEL: @opaque_cycle(
; CHECK: %r = call hotspotcc i32 @jeandle.class_is_primitive
; CHECK: ret i32 %r
define i32 @opaque_cycle(i1 %again, i1 %choose, ptr addrspace(1) %unknown) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  br label %loop
loop:
  %m = phi ptr addrspace(1) [%a, %entry], [%next, %loop]
  %next = select i1 %choose, ptr addrspace(1) %m, ptr addrspace(1) %unknown
  %r = call hotspotcc i32 @jeandle.class_is_primitive(ptr addrspace(1) %m)
  br i1 %again, label %loop, label %exit
exit:
  ret i32 %r
}

; CHECK-LABEL: @null_source(
; CHECK: %r = call hotspotcc i32 @jeandle.class_is_primitive
define i32 @null_source(i1 %choose) {
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %m = select i1 %choose, ptr addrspace(1) %a, ptr addrspace(1) null
  %r = call hotspotcc i32 @jeandle.class_is_primitive(ptr addrspace(1) %m)
  ret i32 %r
}

; CHECK-LABEL: @frozen_poison(
; CHECK: %r = call hotspotcc i32 @jeandle.class_is_primitive
define i32 @frozen_poison(i1 %choose) {
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %m = select i1 %choose, ptr addrspace(1) %a, ptr addrspace(1) poison
  %frozen = freeze ptr addrspace(1) %m
  %r = call hotspotcc i32 @jeandle.class_is_primitive(ptr addrspace(1) %frozen)
  ret i32 %r
}

; CHECK-LABEL: @source_free_cycle(
; CHECK: %r = call hotspotcc i32 @jeandle.class_is_primitive
define i32 @source_free_cycle(i1 %again, ptr addrspace(1) %unknown) {
entry:
  br label %loop
loop:
  %m = phi ptr addrspace(1) [%unknown, %entry], [%m, %loop]
  %r = call hotspotcc i32 @jeandle.class_is_primitive(ptr addrspace(1) %m)
  br i1 %again, label %loop, label %exit
exit:
  ret i32 %r
}

; CHECK-LABEL: @multiple_latches_same(
; CHECK-NOT: call hotspotcc i32 @jeandle.class_is_primitive
; CHECK: ret i32 0
define i32 @multiple_latches_same(i1 %choose, i1 %again, ptr addrspace(1) %unknown) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_1
  %primitive = load ptr addrspace(1), ptr @oop_handle_Mirror_2
  br label %header
header:
  %m = phi ptr addrspace(1) [%a, %entry], [%b, %left], [%b, %right]
  %r = call hotspotcc i32 @jeandle.class_is_primitive(ptr addrspace(1) %m)
  br i1 %choose, label %left, label %right
left:
  br i1 %again, label %header, label %exit
right:
  br i1 %again, label %header, label %exit
exit:
  ret i32 %r
}

; CHECK-LABEL: @multiple_latches_conflict(
; CHECK: %r = call hotspotcc i32 @jeandle.class_is_primitive
; CHECK: ret i32 %r
define i32 @multiple_latches_conflict(i1 %choose, i1 %again, ptr addrspace(1) %unknown) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_1
  %primitive = load ptr addrspace(1), ptr @oop_handle_Mirror_2
  br label %header
header:
  %m = phi ptr addrspace(1) [%a, %entry], [%b, %left], [%primitive, %right]
  %r = call hotspotcc i32 @jeandle.class_is_primitive(ptr addrspace(1) %m)
  br i1 %choose, label %left, label %right
left:
  br i1 %again, label %header, label %exit
right:
  br i1 %again, label %header, label %exit
exit:
  ret i32 %r
}

; CHECK-LABEL: @multiple_latches_opaque(
; CHECK: %r = call hotspotcc i32 @jeandle.class_is_primitive
; CHECK: ret i32 %r
define i32 @multiple_latches_opaque(i1 %choose, i1 %again, ptr addrspace(1) %unknown) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_1
  %primitive = load ptr addrspace(1), ptr @oop_handle_Mirror_2
  br label %header
header:
  %m = phi ptr addrspace(1) [%a, %entry], [%b, %left], [%unknown, %right]
  %r = call hotspotcc i32 @jeandle.class_is_primitive(ptr addrspace(1) %m)
  br i1 %choose, label %left, label %right
left:
  br i1 %again, label %header, label %exit
right:
  br i1 %again, label %header, label %exit
exit:
  ret i32 %r
}

!java-method-compilation = !{}
