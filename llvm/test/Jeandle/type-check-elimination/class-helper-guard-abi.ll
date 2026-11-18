; Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
;
; Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM Exceptions.
; See https://llvm.org/LICENSE.txt for license information.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; RUN: split-file %s %t
; RUN: opt -S -verify-each -passes=type-check-elimination -jeandle-vm-callback-log=%S/Inputs/raw-exact-klass-guards.cblog %t/bad-return.ll | FileCheck %s --check-prefix=RETURN
; RUN: opt -S -verify-each -passes=type-check-elimination -jeandle-vm-callback-log=%S/Inputs/raw-exact-klass-guards.cblog %t/call-forms.ll | FileCheck %s --check-prefix=FORMS
; RUN: opt -S -verify-each -passes=type-check-elimination -jeandle-vm-callback-log=%S/Inputs/raw-exact-klass-guards.cblog %t/variadic.ll | FileCheck %s --check-prefix=VARARG
; RUN: opt -S -verify-each -passes=type-check-elimination -jeandle-vm-callback-log=%S/Inputs/raw-exact-klass-guards.cblog %t/matching-cc.ll | FileCheck %s --check-prefix=MATCHING-CC

;--- bad-return.ll
declare hotspotcc i32 @jeandle.checkcast_nonnull_with_offset(ptr, ptr addrspace(1), i32)
declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1))

; A malformed helper result must not be traced as an i1 through an i32 guard.
; RETURN-LABEL: @wrong_return_guard(
; RETURN: %wrong = call hotspotcc i32 @jeandle.checkcast_nonnull_with_offset
; RETURN: yes:
; RETURN-NEXT: %again = call hotspotcc i1 @jeandle.check_instanceof
; RETURN-NEXT: ret i1 %again
define i1 @wrong_return_guard(ptr addrspace(1) nonnull %o) {
  %wrong = call hotspotcc i32 @jeandle.checkcast_nonnull_with_offset(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %o, i32 56)
  %guard = icmp ne i32 %wrong, 0
  br i1 %guard, label %yes, label %no
yes:
  %again = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %o)
  ret i1 %again
no:
  ret i1 false
}

; RETURN-LABEL: @frozen_wrong_return_guard(
; RETURN: %frozen = freeze i32 %wrong
; RETURN: yes:
; RETURN-NEXT: %again = call hotspotcc i1 @jeandle.check_instanceof
; RETURN-NEXT: ret i1 %again
define i1 @frozen_wrong_return_guard(ptr addrspace(1) nonnull %o) {
  %wrong = call hotspotcc i32 @jeandle.checkcast_nonnull_with_offset(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %o, i32 56)
  %frozen = freeze i32 %wrong
  %guard = icmp ne i32 %frozen, 0
  br i1 %guard, label %yes, label %no
yes:
  %again = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %o)
  ret i1 %again
no:
  ret i1 false
}

!java-method-compilation = !{}

;--- call-forms.ll
declare hotspotcc i1 @jeandle.checkcast_nonnull_with_offset(ptr, ptr addrspace(1), i32)
declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1))

; FORMS-LABEL: @wrong_offset_width_guard(
; FORMS: yes:
; FORMS-NEXT: %again = call hotspotcc i1 @jeandle.check_instanceof
; FORMS-NEXT: ret i1 %again
define i1 @wrong_offset_width_guard(ptr addrspace(1) nonnull %o) {
  %wrong = call hotspotcc i1 (ptr, ptr addrspace(1), i64) @jeandle.checkcast_nonnull_with_offset(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %o, i64 56)
  br i1 %wrong, label %yes, label %no
yes:
  %again = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %o)
  ret i1 %again
no:
  ret i1 false
}

; FORMS-LABEL: @wrong_klass_address_space_guard(
; FORMS: yes:
; FORMS-NEXT: %again = call hotspotcc i1 @jeandle.check_instanceof
; FORMS-NEXT: ret i1 %again
define i1 @wrong_klass_address_space_guard(ptr addrspace(1) nonnull %o) {
  %wrong = call hotspotcc i1 (ptr addrspace(1), ptr addrspace(1), i32) @jeandle.checkcast_nonnull_with_offset(ptr addrspace(1) inttoptr (i64 200 to ptr addrspace(1)), ptr addrspace(1) %o, i32 56)
  br i1 %wrong, label %yes, label %no
yes:
  %again = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %o)
  ret i1 %again
no:
  ret i1 false
}

; FORMS-LABEL: @wrong_cc_guard(
; FORMS: yes:
; FORMS-NEXT: %again = call hotspotcc i1 @jeandle.check_instanceof
; FORMS-NEXT: ret i1 %again
define i1 @wrong_cc_guard(ptr addrspace(1) nonnull %o) {
  %wrong = call i1 @jeandle.checkcast_nonnull_with_offset(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %o, i32 56)
  br i1 %wrong, label %yes, label %no
yes:
  %again = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %o)
  ret i1 %again
no:
  ret i1 false
}

; FORMS-LABEL: @bundled_frozen_guard(
; FORMS: %frozen = freeze i1 %wrong
; FORMS: yes:
; FORMS-NEXT: %again = call hotspotcc i1 @jeandle.check_instanceof
; FORMS-NEXT: ret i1 %again
define i1 @bundled_frozen_guard(ptr addrspace(1) nonnull %o) {
  %wrong = call hotspotcc i1 @jeandle.checkcast_nonnull_with_offset(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %o, i32 56) [ "deopt"(i32 0) ]
  %frozen = freeze i1 %wrong
  br i1 %frozen, label %yes, label %no
yes:
  %again = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %o)
  ret i1 %again
no:
  ret i1 false
}

; FORMS-LABEL: @canonical_frozen_guard(
; FORMS: yes:
; FORMS-NEXT: ret i1 true
define i1 @canonical_frozen_guard(ptr addrspace(1) nonnull %o) {
  %check = call hotspotcc i1 @jeandle.checkcast_nonnull_with_offset(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %o, i32 56)
  %frozen = freeze i1 %check
  br i1 %frozen, label %yes, label %no
yes:
  %again = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %o)
  ret i1 %again
no:
  ret i1 false
}

!java-method-compilation = !{}

;--- variadic.ll
declare i1 @jeandle.checkcast_nonnull_with_offset(ptr, ptr addrspace(1), i32, ...)
declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1))

; VARARG-LABEL: @variadic_guard(
; VARARG: yes:
; VARARG-NEXT: %again = call i1 @jeandle.check_instanceof
; VARARG-NEXT: ret i1 %again
define i1 @variadic_guard(ptr addrspace(1) nonnull %o) {
  %wrong = call i1 (ptr, ptr addrspace(1), i32, ...) @jeandle.checkcast_nonnull_with_offset(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %o, i32 56)
  br i1 %wrong, label %yes, label %no
yes:
  %again = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %o)
  ret i1 %again
no:
  ret i1 false
}

!java-method-compilation = !{}

;--- matching-cc.ll
declare i1 @jeandle.checkcast_nonnull_with_offset(ptr, ptr addrspace(1), i32)
declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1))

; Matching calling conventions remain supported for internal helper fixtures.
; MATCHING-CC-LABEL: @matching_cc_guard(
; MATCHING-CC: yes:
; MATCHING-CC-NEXT: ret i1 true
define i1 @matching_cc_guard(ptr addrspace(1) nonnull %o) {
  %check = call i1 @jeandle.checkcast_nonnull_with_offset(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %o, i32 56)
  br i1 %check, label %yes, label %no
yes:
  %again = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %o)
  ret i1 %again
no:
  ret i1 false
}

!java-method-compilation = !{}
