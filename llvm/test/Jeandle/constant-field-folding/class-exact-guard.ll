; Copyright (c) 2026, The Jeandle-LLVM Authors. All Rights Reserved.
;
; Part of the Jeandle-LLVM project, under the Apache License, Version 2.0 with LLVM Exceptions.
; See https://llvm.org/LICENSE.txt for license information.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; RUN: opt -S -verify-each -passes='constant-field-folding,type-check-elimination' -jeandle-vm-callback-log=%S/Inputs/class-exact-guard.cblog %s | FileCheck %s

@oop_handle_Mirror_0 = external global ptr addrspace(1)
declare hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1))
declare hotspotcc ptr @jeandle.load_klass(ptr addrspace(1))
declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)

; CHECK-LABEL: define i1 @equal_guard(
; CHECK: exact:
; CHECK-NEXT: ret i1 true
; CHECK: other:
; CHECK: call hotspotcc i1 @jeandle.check_instanceof
define i1 @equal_guard(ptr addrspace(1) nonnull %obj) {
entry:
  %mirror = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %expected = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %guard = icmp eq ptr addrspace(1) %mirror, %expected
  br i1 %guard, label %exact, label %other
exact:
  %yes = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %yes
other:
  %maybe_subclass = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %maybe_subclass
}

; CHECK-LABEL: define i1 @unequal_guard(
; CHECK: exact:
; CHECK-NEXT: ret i1 true
; CHECK: other:
; CHECK: call hotspotcc i1 @jeandle.check_instanceof
define i1 @unequal_guard(ptr addrspace(1) nonnull %obj) {
entry:
  %mirror = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %expected = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %guard = icmp ne ptr addrspace(1) %mirror, %expected
  br i1 %guard, label %other, label %exact
exact:
  %yes = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %yes
other:
  %maybe_subclass = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %maybe_subclass
}

; CHECK-LABEL: define i1 @swapped_guard(
; CHECK: exact:
; CHECK-NEXT: ret i1 true
; CHECK: other:
; CHECK: call hotspotcc i1 @jeandle.check_instanceof
define i1 @swapped_guard(ptr addrspace(1) nonnull %obj) {
entry:
  %mirror = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %expected = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %guard = icmp eq ptr addrspace(1) %expected, %mirror
  br i1 %guard, label %exact, label %other
exact:
  %yes = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %yes
other:
  %maybe_subclass = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %maybe_subclass
}

!java-method-compilation = !{}
