; Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
;
; Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM Exceptions.
; See https://llvm.org/LICENSE.txt for license information.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; RUN: opt -S -verify-each -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/class-properties.cblog %s | FileCheck %s

declare hotspotcc nonnull ptr addrspace(1) @jeandle.get_class(ptr addrspace(1))
declare hotspotcc ptr @jeandle.load_klass(ptr addrspace(1))
declare hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1))
declare hotspotcc i32 @jeandle.class_is_primitive(ptr addrspace(1))
declare hotspotcc i32 @jeandle.class_is_interface(ptr addrspace(1))

; CHECK-LABEL: @inverse(
; CHECK: [[K:%.*]] = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %o)
; CHECK-NOT: call hotspotcc ptr @jeandle.load_mirror_klass
; CHECK: ret ptr [[K]]
define ptr @inverse(ptr addrspace(1) %o) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %o)
  %k = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %m)
  ret ptr %k
}

; CHECK-LABEL: @not_primitive(
; CHECK: ret i32 0
define i32 @not_primitive(ptr addrspace(1) %o) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %o)
  %r = call hotspotcc i32 @jeandle.class_is_primitive(ptr addrspace(1) %m)
  ret i32 %r
}

; CHECK-LABEL: @not_interface(
; CHECK: ret i32 0
define i32 @not_interface(ptr addrspace(1) %o) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %o)
  %r = call hotspotcc i32 @jeandle.class_is_interface(ptr addrspace(1) %m)
  ret i32 %r
}

; CHECK-LABEL: @unknown(
; CHECK: %r = call hotspotcc i32 @jeandle.class_is_primitive(ptr addrspace(1) %m)
; CHECK: ret i32 %r
define i32 @unknown(ptr addrspace(1) %m) {
  %r = call hotspotcc i32 @jeandle.class_is_primitive(ptr addrspace(1) %m)
  ret i32 %r
}

; A mismatched calling convention does not establish a Java mirror origin.
; CHECK-LABEL: @wrong_cc(
; CHECK: %m = call ptr addrspace(1) @jeandle.get_class
; CHECK: %r = call hotspotcc i32 @jeandle.class_is_interface(ptr addrspace(1) %m)
define i32 @wrong_cc(ptr addrspace(1) %o) {
  %m = call ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %o)
  %r = call hotspotcc i32 @jeandle.class_is_interface(ptr addrspace(1) %m)
  ret i32 %r
}

; Nonzero derived addresses do not retain Class identity.
; CHECK-LABEL: @derived(
; CHECK: %r = call hotspotcc i32 @jeandle.class_is_primitive(ptr addrspace(1) %p)
define i32 @derived(ptr addrspace(1) %o) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %o)
  %p = getelementptr i8, ptr addrspace(1) %m, i64 1
  %r = call hotspotcc i32 @jeandle.class_is_primitive(ptr addrspace(1) %p)
  ret i32 %r
}

!java-method-compilation = !{}
