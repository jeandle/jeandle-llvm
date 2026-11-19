; Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; RUN: opt -S -verify-each -passes='constant-field-folding,constant-field-folding' -jeandle-vm-callback-log=%S/Inputs/class-dynamic-mirror-origin.cblog %s | FileCheck %s

declare hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1)) memory(read) nounwind willreturn
declare hotspotcc i1 @jeandle.check_klass_subtype(ptr, ptr)

; CHECK-LABEL: @distinct(
; CHECK: [[DISTINCT:%.*]] = icmp ne ptr %ka, %kb
; CHECK-NEXT: call void @llvm.assume(i1 [[DISTINCT]])
; CHECK-NOT: @llvm.assume
; CHECK: call hotspotcc i1 @jeandle.check_klass_subtype
define i1 @distinct(ptr addrspace(1) nonnull %a, ptr addrspace(1) nonnull %b) {
entry:
  %same = icmp eq ptr addrspace(1) %a, %b
  br i1 %same, label %identity, label %klass
identity:
  ret i1 true
klass:
  %ka = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %a)
  %kb = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %b)
  %pa = icmp eq ptr %ka, null
  %pb = icmp eq ptr %kb, null
  %primitive = or i1 %pa, %pb
  br i1 %primitive, label %fail, label %reference
fail:
  ret i1 false
reference:
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %ka, ptr %kb)
  ret i1 %r
}

; CHECK-LABEL: @primitive_possible(
; CHECK-NOT: @llvm.assume
; CHECK: call hotspotcc i1 @jeandle.check_klass_subtype
; CHECK-NOT: @llvm.assume
; CHECK: }
define i1 @primitive_possible(ptr addrspace(1) nonnull %a, ptr addrspace(1) nonnull %b) {
entry:
  %same = icmp eq ptr addrspace(1) %a, %b
  br i1 %same, label %identity, label %klass
identity:
  ret i1 true
klass:
  %ka = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %a)
  %kb = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %b)
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %ka, ptr %kb)
  ret i1 %r
}

; CHECK-LABEL: @no_identity_guard(
; CHECK-NOT: @llvm.assume
; CHECK: call hotspotcc i1 @jeandle.check_klass_subtype
; CHECK-NOT: @llvm.assume
; CHECK: }
define i1 @no_identity_guard(ptr addrspace(1) nonnull %a, ptr addrspace(1) nonnull %b) {
entry:
  %ka = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %a)
  %kb = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %b)
  %pa = icmp eq ptr %ka, null
  %pb = icmp eq ptr %kb, null
  %primitive = or i1 %pa, %pb
  br i1 %primitive, label %fail, label %reference
fail:
  ret i1 false
reference:
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %ka, ptr %kb)
  ret i1 %r
}

; CHECK-LABEL: @swapped(
; CHECK: [[DISTINCT:%.*]] = icmp ne ptr %ka, %kb
; CHECK-NEXT: call void @llvm.assume(i1 [[DISTINCT]])
; CHECK-NOT: @llvm.assume
; CHECK: call hotspotcc i1 @jeandle.check_klass_subtype
define i1 @swapped(ptr addrspace(1) nonnull %a, ptr addrspace(1) nonnull %b) {
entry:
  %same = icmp eq ptr addrspace(1) %b, %a
  br i1 %same, label %identity, label %klass
identity:
  ret i1 true
klass:
  %ka = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %a)
  %kb = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %b)
  %pa = icmp eq ptr %ka, null
  %pb = icmp eq ptr %kb, null
  %primitive = or i1 %pa, %pb
  br i1 %primitive, label %fail, label %reference
fail:
  ret i1 false
reference:
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %ka, ptr %kb)
  ret i1 %r
}

; A later comparison cannot establish a fact at the earlier subtype query.
; CHECK-LABEL: @non_dominating_compare(
; CHECK-NOT: @llvm.assume
; CHECK: call hotspotcc i1 @jeandle.check_klass_subtype
; CHECK-NOT: @llvm.assume
; CHECK: icmp ne ptr addrspace(1) %a, %b
; CHECK: }
define i1 @non_dominating_compare(ptr addrspace(1) nonnull %a, ptr addrspace(1) nonnull %b, i1 %choice) {
entry:
  %ka = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %a)
  %kb = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %b)
  %pa = icmp eq ptr %ka, null
  %pb = icmp eq ptr %kb, null
  %primitive = or i1 %pa, %pb
  br i1 %primitive, label %fail, label %reference
fail:
  ret i1 false
reference:
  %r = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %ka, ptr %kb)
  br i1 %choice, label %later_compare, label %result
later_compare:
  %late = icmp ne ptr addrspace(1) %a, %b
  ret i1 %late
result:
  ret i1 %r
}
!java-method-compilation = !{}
