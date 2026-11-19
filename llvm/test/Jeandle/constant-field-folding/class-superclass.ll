; Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
;
; Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM Exceptions.
; See https://llvm.org/LICENSE.txt for license information.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; RUN: opt -S -verify-each -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/class-superclass.cblog %s | FileCheck %s

@oop_handle_Mirror_0 = external global ptr addrspace(1)
@oop_handle_Mirror_1 = external global ptr addrspace(1)
@oop_handle_Mirror_2 = external global ptr addrspace(1)
@oop_handle_Mirror_3 = external global ptr addrspace(1)
declare hotspotcc ptr addrspace(1) @jeandle.class_get_superclass(ptr addrspace(1))

; CHECK-LABEL: @common_superclass(
; CHECK: [[SUPER:%.*]] = load ptr addrspace(1), ptr @oop_handle_Mirror_9
; CHECK-NOT: call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass
; CHECK: ret ptr addrspace(1) [[SUPER]]
define ptr addrspace(1) @common_superclass(i1 %choose) {
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_1
  %m = select i1 %choose, ptr addrspace(1) %a, ptr addrspace(1) %b
  %r = call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass(ptr addrspace(1) %m)
  ret ptr addrspace(1) %r
}

; CHECK-LABEL: @null_superclass(
; CHECK: ret ptr addrspace(1) null
define ptr addrspace(1) @null_superclass(i1 %choose) {
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_2
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_3
  %m = select i1 %choose, ptr addrspace(1) %a, ptr addrspace(1) %b
  %r = call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass(ptr addrspace(1) %m)
  ret ptr addrspace(1) %r
}

; CHECK-LABEL: @different_superclass(
; CHECK: %r = call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass
; CHECK: ret ptr addrspace(1) %r
define ptr addrspace(1) @different_superclass(i1 %choose) {
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_2
  %m = select i1 %choose, ptr addrspace(1) %a, ptr addrspace(1) %b
  %r = call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass(ptr addrspace(1) %m)
  ret ptr addrspace(1) %r
}

; CHECK-LABEL: @dynamic_superclass(
; CHECK: %r = call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass
define ptr addrspace(1) @dynamic_superclass(ptr addrspace(1) %m) {
  %r = call hotspotcc ptr addrspace(1) @jeandle.class_get_superclass(ptr addrspace(1) %m)
  ret ptr addrspace(1) %r
}

!java-method-compilation = !{}
