; Copyright (c) 2026, The Jeandle-LLVM Authors. All Rights Reserved.
;
; Part of the Jeandle-LLVM project, under the Apache License, Version 2.0 with LLVM Exceptions.
; See https://llvm.org/LICENSE.txt for license information.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; RUN: opt -S -verify-each -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/class-mirror-getclass-compare.cblog %s | FileCheck %s

; This standalone pass preserves calls whose effects are unknown.
; The checks below only assert comparison canonicalization.
; Mirror 0 is a reference Class (klass 100), mirror 1 is a primitive Class.

@oop_handle_Mirror_0 = external global ptr addrspace(1)
@oop_handle_Mirror_1 = external global ptr addrspace(1)
declare hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1))
declare hotspotcc ptr @jeandle.load_klass(ptr addrspace(1))
declare hotspotcc ptr addrspace(1) @jeandle.klass_mirror(ptr)

; CHECK-LABEL: @eq_origin_left(
; CHECK: [[K:%.*]] = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %o)
; CHECK: icmp eq ptr [[K]], inttoptr (i64 100 to ptr)
define i1 @eq_origin_left(ptr addrspace(1) %o) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %o)
  %c = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %r = icmp eq ptr addrspace(1) %m, %c
  ret i1 %r
}

; CHECK-LABEL: @ne_origin_right(
; CHECK: [[K:%.*]] = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %o)
; CHECK: icmp ne ptr inttoptr (i64 100 to ptr), [[K]]
define i1 @ne_origin_right(ptr addrspace(1) %o) {
  %c = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %o)
  %r = icmp ne ptr addrspace(1) %c, %m
  ret i1 %r
}

; A constant primitive mirror never equals a getClass result.
; CHECK-LABEL: @eq_primitive_const(
; CHECK: ret i1 false
define i1 @eq_primitive_const(ptr addrspace(1) %o) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %o)
  %c = load ptr addrspace(1), ptr @oop_handle_Mirror_1
  %r = icmp eq ptr addrspace(1) %m, %c
  ret i1 %r
}

; CHECK-LABEL: @ne_primitive_const(
; CHECK: ret i1 true
define i1 @ne_primitive_const(ptr addrspace(1) %o) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %o)
  %c = load ptr addrspace(1), ptr @oop_handle_Mirror_1
  %r = icmp ne ptr addrspace(1) %m, %c
  ret i1 %r
}

; Without a constant operand the comparison stays on mirrors; the origin
; rewrite must not fire on a klass_mirror producer either.
; CHECK-LABEL: @dynamic_both(
; CHECK: icmp eq ptr addrspace(1) %m, %o
; CHECK: ret i1 %r
define i1 @dynamic_both(ptr addrspace(1) %o) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %o)
  %r = icmp eq ptr addrspace(1) %m, %o
  ret i1 %r
}

; CHECK-LABEL: @klass_mirror_origin(
; CHECK: icmp eq ptr addrspace(1) %m, %c
; CHECK: ret i1 %r
define i1 @klass_mirror_origin(ptr %k) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.klass_mirror(ptr %k)
  %c = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %r = icmp eq ptr addrspace(1) %m, %c
  ret i1 %r
}

; A wrong-signature get_class lookalike must not be rewritten.
; CHECK-LABEL: @wrong_cc(
; CHECK: %m = call ptr addrspace(1) @jeandle.get_class
; CHECK: %r = icmp eq ptr addrspace(1) %m, %c
define i1 @wrong_cc(ptr addrspace(1) %o) {
  %m = call ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %o)
  %c = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %r = icmp eq ptr addrspace(1) %m, %c
  ret i1 %r
}

; Two getClass results compare on their header Klass values.
; CHECK-LABEL: @getclass_vs_getclass(
; CHECK: [[A:%.*]] = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %x)
; CHECK: [[B:%.*]] = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %y)
; CHECK: icmp eq ptr [[A]], [[B]]
define i1 @getclass_vs_getclass(ptr addrspace(1) %x, ptr addrspace(1) %y) {
  %mx = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %x)
  %my = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %y)
  %r = icmp eq ptr addrspace(1) %mx, %my
  ret i1 %r
}

; Freeze wrappers around the getClass result do not hide the origin.
; CHECK-LABEL: @frozen_origin(
; CHECK: [[K:%.*]] = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %o)
; CHECK: icmp eq ptr [[K]], inttoptr (i64 100 to ptr)
define i1 @frozen_origin(ptr addrspace(1) %o) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %o)
  %f = freeze ptr addrspace(1) %m
  %c = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %r = icmp eq ptr addrspace(1) %f, %c
  ret i1 %r
}

!java-method-compilation = !{}
