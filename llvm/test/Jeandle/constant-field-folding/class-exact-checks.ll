; Copyright (c) 2026, The Jeandle-LLVM Authors. All Rights Reserved.
;
; Part of the Jeandle-LLVM project, under the Apache License, Version 2.0 with LLVM Exceptions.
; See https://llvm.org/LICENSE.txt for license information.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; RUN: opt -S -verify-each -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/class-exact-checks.cblog %s | FileCheck %s

@Klass.secondary_super_cache_offset = private constant i32 32
declare hotspotcc ptr @jeandle.load_klass(ptr addrspace(1))
declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1))
declare hotspotcc i1 @jeandle.checkcast_nonnull_with_offset(ptr, ptr addrspace(1), i32)
declare hotspotcc i1 @jeandle.check_klass_subtype(ptr, ptr)
declare hotspotcc i1 @jeandle.check_klass_subtype_with_offset(ptr, ptr, i32)

; CHECK-LABEL: define i1 @final_class(
; CHECK-NOT: @jeandle.check
; CHECK: [[K:%.*]] = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
; CHECK: [[R:%.*]] = icmp eq ptr [[K]], inttoptr (i64 100 to ptr)
; CHECK-NEXT: ret i1 [[R]]
define i1 @final_class(ptr addrspace(1) nonnull %obj) {
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %r
}

; CHECK-LABEL: define i1 @primitive_array(
; CHECK-NOT: @jeandle.check
; CHECK: [[K:%.*]] = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
; CHECK: [[R:%.*]] = icmp eq ptr [[K]], inttoptr (i64 200 to ptr)
; CHECK-NEXT: ret i1 [[R]]
define i1 @primitive_array(ptr addrspace(1) nonnull %obj) {
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %obj)
  ret i1 %r
}

; CHECK-LABEL: define i1 @final_element_array(
; CHECK-NOT: @jeandle.check
; CHECK: [[K:%.*]] = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
; CHECK: [[R:%.*]] = icmp eq ptr [[K]], inttoptr (i64 300 to ptr)
; CHECK-NEXT: ret i1 [[R]]
define i1 @final_element_array(ptr addrspace(1) nonnull %obj) {
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 300 to ptr), ptr addrspace(1) %obj)
  ret i1 %r
}

; Object[] and non-final leaf classes remain subtype checks.
; CHECK-LABEL: define i1 @covariant_array(
; CHECK: call hotspotcc i1 @jeandle.checkcast_nonnull_with_offset(ptr inttoptr (i64 400 to ptr), ptr addrspace(1) %obj, i32 56)
define i1 @covariant_array(ptr addrspace(1) nonnull %obj) {
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 400 to ptr), ptr addrspace(1) %obj)
  ret i1 %r
}

; CHECK-LABEL: define i1 @nonfinal_leaf(
; CHECK: call hotspotcc i1 @jeandle.checkcast_nonnull_with_offset(ptr inttoptr (i64 600 to ptr), ptr addrspace(1) %obj, i32 56)
define i1 @nonfinal_leaf(ptr addrspace(1) nonnull %obj) {
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 600 to ptr), ptr addrspace(1) %obj)
  ret i1 %r
}

; CHECK-LABEL: define i1 @secondary_target(
; CHECK: call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 500 to ptr), ptr addrspace(1) %obj)
define i1 @secondary_target(ptr addrspace(1) nonnull %obj) {
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 500 to ptr), ptr addrspace(1) %obj)
  ret i1 %r
}

; CHECK-LABEL: define i1 @final_klass_target(
; CHECK-NOT: @jeandle.check
; CHECK: [[R:%.*]] = icmp eq ptr %sub, inttoptr (i64 100 to ptr)
; CHECK-NEXT: ret i1 [[R]]
define i1 @final_klass_target(ptr %sub) {
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %sub, ptr inttoptr (i64 100 to ptr))
  ret i1 %r
}

; CHECK-LABEL: define i1 @wrong_cc(
; CHECK: call i1 @jeandle.check_instanceof
define i1 @wrong_cc(ptr addrspace(1) nonnull %obj) {
  %r = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %r
}

; CHECK-LABEL: define i1 @bundled_check(
; CHECK: call hotspotcc i1 @jeandle.check_instanceof{{.*}}[ "deopt"(i32 7) ]
define i1 @bundled_check(ptr addrspace(1) nonnull %obj) {
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj) [ "deopt"(i32 7) ]
  ret i1 %r
}

!java-method-compilation = !{}
