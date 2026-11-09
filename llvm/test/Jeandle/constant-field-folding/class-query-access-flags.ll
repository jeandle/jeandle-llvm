; Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
;
; Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM Exceptions.
; See https://llvm.org/LICENSE.txt for license information.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; RUN: opt -S -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/class-query-access-flags.cblog %s | FileCheck %s --check-prefixes=DEFAULT,COMMON
; RUN: sed 's/^; INJECT: //' %s | opt -S -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/class-query-access-flags.cblog | FileCheck %s --check-prefixes=INJECTED,COMMON
;
; Standalone tests use the stock defaults. A deliberately different set of bits
; proves that the pass reads the module rather than always returning 1041.
; INJECT: @AccessFlags.jvm_acc_public = private constant i32 4
; INJECT: @AccessFlags.jvm_acc_final = private constant i32 32
; INJECT: @AccessFlags.jvm_acc_abstract = private constant i32 128

@oop_handle_Mirror_0 = external global ptr addrspace(1)
@oop_handle_Mirror_1 = external global ptr addrspace(1)
@oop_handle_Mirror_2 = external global ptr addrspace(1)

declare hotspotcc i32 @jeandle.class_get_modifiers(ptr addrspace(1))
declare hotspotcc i32 @jeandle.class_get_access_flags(ptr addrspace(1))

; COMMON-LABEL: define i32 @primitive_modifiers(
; COMMON-NOT: call hotspotcc i32 @jeandle.class_
; DEFAULT: ret i32 1041
; INJECTED: ret i32 164
define i32 @primitive_modifiers() #0 gc "hotspotgc" {
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %r = call hotspotcc i32 @jeandle.class_get_modifiers(ptr addrspace(1) %a)
  ret i32 %r
}

; COMMON-LABEL: define i32 @primitive_access_flags(
; COMMON-NOT: call hotspotcc i32 @jeandle.class_
; DEFAULT: ret i32 1041
; INJECTED: ret i32 164
define i32 @primitive_access_flags() #0 gc "hotspotgc" {
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %r = call hotspotcc i32 @jeandle.class_get_access_flags(ptr addrspace(1) %a)
  ret i32 %r
}

; COMMON-LABEL: define i32 @merged_primitive_modifiers(
; COMMON-NOT: call hotspotcc i32 @jeandle.class_
; DEFAULT: ret i32 1041
; INJECTED: ret i32 164
define i32 @merged_primitive_modifiers(i1 %c) #0 gc "hotspotgc" {
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_1
  %mirror = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %b
  %r = call hotspotcc i32 @jeandle.class_get_modifiers(ptr addrspace(1) %mirror)
  ret i32 %r
}

; COMMON-LABEL: define i32 @merged_primitive_access_flags(
; COMMON-NOT: call hotspotcc i32 @jeandle.class_
; DEFAULT: ret i32 1041
; INJECTED: ret i32 164
define i32 @merged_primitive_access_flags(i1 %c) #0 gc "hotspotgc" {
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %b = load ptr addrspace(1), ptr @oop_handle_Mirror_1
  %mirror = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %b
  %r = call hotspotcc i32 @jeandle.class_get_access_flags(ptr addrspace(1) %mirror)
  ret i32 %r
}

; COMMON-LABEL: define i32 @reference_modifiers(
; COMMON-NOT: call hotspotcc i32 @jeandle.class_
; COMMON: ret i32 17
define i32 @reference_modifiers() #0 gc "hotspotgc" {
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_2
  %r = call hotspotcc i32 @jeandle.class_get_modifiers(ptr addrspace(1) %a)
  ret i32 %r
}

; COMMON-LABEL: define i32 @reference_access_flags(
; COMMON-NOT: call hotspotcc i32 @jeandle.class_
; COMMON: ret i32 33
define i32 @reference_access_flags() #0 gc "hotspotgc" {
  %a = load ptr addrspace(1), ptr @oop_handle_Mirror_2
  %r = call hotspotcc i32 @jeandle.class_get_access_flags(ptr addrspace(1) %a)
  ret i32 %r
}

attributes #0 = { "java-method"="1" }
!java-method-compilation = !{}
