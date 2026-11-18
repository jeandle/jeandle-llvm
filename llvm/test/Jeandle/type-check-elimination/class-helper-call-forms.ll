; Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
;
; Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM Exceptions.
; See https://llvm.org/LICENSE.txt for license information.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; RUN: opt -S -verify-each -passes=type-check-elimination -jeandle-vm-callback-log=%S/Inputs/class-helper-call-forms.cblog %s | FileCheck %s

declare hotspotcc i1 @jeandle.checkcast_nonnull_with_offset()
declare hotspotcc i32 @jeandle.check_klass_subtype(ptr, ptr)
declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1))
declare hotspotcc i1 @jeandle.check_klass_subtype_with_offset(ptr, ptr, i32)

; CHECK-LABEL: @wrong_arity(
; CHECK: %r = call hotspotcc i1 @jeandle.checkcast_nonnull_with_offset()
; CHECK: ret i1 %r
define i1 @wrong_arity() {
  %r = call hotspotcc i1 @jeandle.checkcast_nonnull_with_offset()
  ret i1 %r
}

; CHECK-LABEL: @wrong_cc(
; CHECK: %r = call i1 @jeandle.check_instanceof
; CHECK: ret i1 %r
define i1 @wrong_cc(ptr addrspace(1) %o) {
  %r = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %o)
  ret i1 %r
}

; CHECK-LABEL: @bundles(
; CHECK: %r = call hotspotcc i1 @jeandle.check_instanceof{{.*}}[ "deopt"(i32 0) ]
; CHECK: ret i1 %r
define i1 @bundles(ptr addrspace(1) %o) {
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %o) [ "deopt"(i32 0) ]
  ret i1 %r
}

; CHECK-LABEL: @tail_check(
; CHECK: %r = musttail call hotspotcc i1 @jeandle.check_instanceof
; CHECK: ret i1 %r
define hotspotcc i1 @tail_check(ptr %k, ptr addrspace(1) %o) {
  %r = musttail call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %o)
  ret i1 %r
}

; CHECK-LABEL: @constant_offset_subtype(
; CHECK-NEXT: ret i1 true
define i1 @constant_offset_subtype() {
  %r = call hotspotcc i1 @jeandle.check_klass_subtype_with_offset(ptr inttoptr (i64 200 to ptr), ptr inttoptr (i64 100 to ptr), i32 56)
  ret i1 %r
}

; CHECK-LABEL: @wrong_return_type(
; CHECK: %r = call hotspotcc i32 @jeandle.check_klass_subtype
; CHECK: ret i32 %r
define i32 @wrong_return_type() {
  %r = call hotspotcc i32 @jeandle.check_klass_subtype(ptr inttoptr (i64 200 to ptr), ptr inttoptr (i64 100 to ptr))
  ret i32 %r
}

; CHECK-LABEL: @wrong_offset_type(
; CHECK: %r = call hotspotcc i1 @jeandle.check_klass_subtype_with_offset({{.*}}i64 56)
; CHECK: ret i1 %r
define i1 @wrong_offset_type() {
  %r = call hotspotcc i1 (ptr, ptr, i64) @jeandle.check_klass_subtype_with_offset(ptr inttoptr (i64 200 to ptr), ptr inttoptr (i64 100 to ptr), i64 56)
  ret i1 %r
}

; CHECK-LABEL: @wrong_address_space(
; CHECK: %r = call hotspotcc i1 @jeandle.check_instanceof(ptr {{.*}}, ptr %o)
; CHECK: ret i1 %r
define i1 @wrong_address_space(ptr %o) {
  %r = call hotspotcc i1 (ptr, ptr) @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr %o)
  ret i1 %r
}

!java-method-compilation = !{}
