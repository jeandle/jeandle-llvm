; Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
;
; Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM Exceptions.
; See https://llvm.org/LICENSE.txt for license information.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; RUN: opt -S -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/class-check-offset.cblog %s | FileCheck %s
; RUN: sed '/^@Klass.secondary_super_cache_offset =/d' %s | opt -S -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/class-check-offset.cblog | FileCheck %s --check-prefix=MISSING

@Klass.secondary_super_cache_offset = private constant i32 32

@oop_handle_CallSite_0 = external dso_local global ptr addrspace(1)
declare hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1))
declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1))
declare hotspotcc i1 @jeandle.checkcast_nonnull_with_offset(ptr, ptr addrspace(1), i32)
declare hotspotcc i1 @jeandle.check_klass_subtype(ptr, ptr)
declare hotspotcc i1 @jeandle.check_klass_subtype_with_offset(ptr, ptr, i32)

; MISSING-LABEL: define i1 @constant_chain(
; MISSING: call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 234567 to ptr), ptr addrspace(1) %obj)
; CHECK-LABEL: define i1 @constant_chain(
; CHECK: call hotspotcc i1 @jeandle.checkcast_nonnull_with_offset(ptr inttoptr (i64 234567 to ptr), ptr addrspace(1) %obj, i32 56)
define i1 @constant_chain(ptr addrspace(1) %obj) #0 gc "hotspotgc" {
  %site = load ptr addrspace(1), ptr @oop_handle_CallSite_0
  %addr = getelementptr i8, ptr addrspace(1) %site, i64 16
  %mirror = load ptr addrspace(1), ptr addrspace(1) %addr
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %klass, ptr addrspace(1) %obj)
  ret i1 %r
}

; CHECK-LABEL: define i1 @dynamic_target(
; CHECK: call hotspotcc i1 @jeandle.check_instanceof(ptr %klass, ptr addrspace(1) %obj)
define i1 @dynamic_target(ptr %klass, ptr addrspace(1) %obj) #0 gc "hotspotgc" {
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %klass, ptr addrspace(1) %obj)
  ret i1 %r
}

; CHECK-LABEL: define i1 @null_target(
; CHECK: call hotspotcc i1 @jeandle.check_instanceof(ptr null, ptr addrspace(1) %obj)
define i1 @null_target(ptr addrspace(1) %obj) #0 gc "hotspotgc" {
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr null, ptr addrspace(1) %obj)
  ret i1 %r
}

; CHECK-LABEL: define i1 @zero_offset(
; CHECK: call hotspotcc i1 @jeandle.checkcast_nonnull_with_offset(ptr inttoptr (i64 234568 to ptr), ptr addrspace(1) %obj, i32 0)
define i1 @zero_offset(ptr addrspace(1) %obj) #0 gc "hotspotgc" {
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 234568 to ptr), ptr addrspace(1) %obj)
  ret i1 %r
}

; CHECK-LABEL: define i1 @secondary_offset(
; CHECK: call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 234569 to ptr), ptr addrspace(1) %obj)
define i1 @secondary_offset(ptr addrspace(1) %obj) #0 gc "hotspotgc" {
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 234569 to ptr), ptr addrspace(1) %obj)
  ret i1 %r
}
attributes #0 = { "java-method"="1" }

; MISSING-LABEL: define i1 @klass_primary(
; MISSING: call hotspotcc i1 @jeandle.check_klass_subtype(ptr %sub, ptr inttoptr (i64 234567 to ptr))
; CHECK-LABEL: define i1 @klass_primary(
; CHECK: call hotspotcc i1 @jeandle.check_klass_subtype_with_offset(ptr %sub, ptr inttoptr (i64 234567 to ptr), i32 56)
define i1 @klass_primary(ptr %sub) {
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %sub, ptr inttoptr (i64 234567 to ptr))
  ret i1 %r
}

; CHECK-LABEL: define i1 @klass_secondary(
; CHECK: call hotspotcc i1 @jeandle.check_klass_subtype(ptr %sub, ptr inttoptr (i64 234569 to ptr))
define i1 @klass_secondary(ptr %sub) {
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %sub, ptr inttoptr (i64 234569 to ptr))
  ret i1 %r
}

; CHECK-LABEL: define i1 @klass_null(
; CHECK: call hotspotcc i1 @jeandle.check_klass_subtype(ptr %sub, ptr null)
define i1 @klass_null(ptr %sub) {
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %sub, ptr null)
  ret i1 %r
}
!java-method-compilation = !{}
