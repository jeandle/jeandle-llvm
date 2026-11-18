; Copyright (c) 2026, The Jeandle-LLVM Authors. All Rights Reserved.
;
; Part of the Jeandle-LLVM project, under the Apache License, Version 2.0 with LLVM Exceptions.
; See https://llvm.org/LICENSE.txt for license information.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; RUN: opt -S -verify-each -passes='function(constant-field-folding),java-operation-lower<phase=1>,function(early-cse,instcombine,simplifycfg,adce),java-operation-deletion' -jeandle-vm-callback-log=%S/Inputs/class-mirror-getclass-compare.cblog %s | FileCheck %s
;
; The get_class body is the uncompressed-Klass form emitted by
; RuntimeDefinedJavaOps::define_get_class. Phase-1 lowering must expose and
; remove its two mirror indirections when only exact type equality is needed.
; Complete-function checks cover every instruction, including those before
; the rewritten comparison.

target datalayout = "e-p:64:64-p1:64:64-p3:32:32"
@Klass.java_mirror_offset = constant i32 112
@oop_handle_Mirror_0 = external global ptr addrspace(1)
@oop_handle_Mirror_1 = external global ptr addrspace(1)

define private hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) nocapture %oop) noinline "lower-phase"="1" nounwind "gc-leaf-function" {
entry:
  %addr = getelementptr inbounds i8, ptr addrspace(1) %oop, i64 8
  %klass = load atomic ptr, ptr addrspace(1) %addr unordered, align 8
  ret ptr %klass
}

define private hotspotcc nonnull ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj) noinline "lower-phase"="1" nounwind "gc-leaf-function" {
entry:
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %mirror_offset = load i32, ptr @Klass.java_mirror_offset
  %handle_addr = getelementptr inbounds i8, ptr %klass, i32 %mirror_offset
  %handle = load ptr, ptr %handle_addr
  %mirror = load ptr addrspace(1), ptr %handle
  ret ptr addrspace(1) %mirror
}

define private hotspotcc i1 @jeandle.check_exact_klass(ptr %expected, ptr %actual) noinline "lower-phase"="1" nounwind "gc-leaf-function" {
entry:
  %is_exact = icmp eq ptr %actual, %expected
  ret i1 %is_exact
}

; CHECK-LABEL: define i1 @eq_origin_left(
; CHECK-NEXT: entry:
; CHECK-NEXT: [[ADDR:%.*]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %o, i64 8
; CHECK-NEXT: [[K:%.*]] = load atomic ptr, ptr addrspace(1) [[ADDR]] unordered, align 8
; CHECK-NEXT: [[EQ:%.*]] = icmp eq ptr [[K]], inttoptr (i64 100 to ptr)
; CHECK-NEXT: ret i1 [[EQ]]
; CHECK-NEXT: }
define i1 @eq_origin_left(ptr addrspace(1) nonnull %o) {
entry:
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %o)
  %c = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %r = icmp eq ptr addrspace(1) %m, %c
  ret i1 %r
}

; CHECK-LABEL: define i1 @ne_origin_right(
; CHECK-NEXT: entry:
; CHECK-NEXT: [[ADDR:%.*]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %o, i64 8
; CHECK-NEXT: [[K:%.*]] = load atomic ptr, ptr addrspace(1) [[ADDR]] unordered, align 8
; CHECK-NEXT: [[NE:%.*]] = icmp ne ptr [[K]], inttoptr (i64 100 to ptr)
; CHECK-NEXT: ret i1 [[NE]]
; CHECK-NEXT: }
define i1 @ne_origin_right(ptr addrspace(1) nonnull %o) {
entry:
  %c = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %o)
  %r = icmp ne ptr addrspace(1) %c, %m
  ret i1 %r
}

; CHECK-LABEL: define i1 @eq_primitive_const(
; CHECK-NEXT: entry:
; CHECK-NEXT: ret i1 false
; CHECK-NEXT: }
define i1 @eq_primitive_const(ptr addrspace(1) nonnull %o) {
entry:
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %o)
  %c = load ptr addrspace(1), ptr @oop_handle_Mirror_1
  %r = icmp eq ptr addrspace(1) %m, %c
  ret i1 %r
}

; CHECK-LABEL: define i1 @ne_primitive_const(
; CHECK-NEXT: entry:
; CHECK-NEXT: ret i1 true
; CHECK-NEXT: }
define i1 @ne_primitive_const(ptr addrspace(1) nonnull %o) {
entry:
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %o)
  %c = load ptr addrspace(1), ptr @oop_handle_Mirror_1
  %r = icmp ne ptr addrspace(1) %m, %c
  ret i1 %r
}

; CHECK-LABEL: define i1 @getclass_vs_getclass(
; CHECK-NEXT: entry:
; CHECK-NEXT: [[XA:%.*]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %x, i64 8
; CHECK-NEXT: [[X:%.*]] = load atomic ptr, ptr addrspace(1) [[XA]] unordered, align 8
; CHECK-NEXT: [[YA:%.*]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %y, i64 8
; CHECK-NEXT: [[Y:%.*]] = load atomic ptr, ptr addrspace(1) [[YA]] unordered, align 8
; CHECK-NEXT: [[EQ:%.*]] = icmp eq ptr [[X]], [[Y]]
; CHECK-NEXT: ret i1 [[EQ]]
; CHECK-NEXT: }
define i1 @getclass_vs_getclass(ptr addrspace(1) nonnull %x, ptr addrspace(1) nonnull %y) {
entry:
  %mx = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %x)
  %my = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %y)
  %r = icmp eq ptr addrspace(1) %mx, %my
  ret i1 %r
}

!java-method-compilation = !{}
