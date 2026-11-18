; Copyright (c) 2026, The Jeandle-LLVM Authors. All Rights Reserved.
;
; Part of the Jeandle-LLVM project, under the Apache License, Version 2.0 with LLVM Exceptions.
; See https://llvm.org/LICENSE.txt for license information.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; RUN: split-file %s %t
; RUN: opt -S -verify-each -passes=type-check-elimination -jeandle-vm-callback-log=%S/Inputs/raw-exact-klass-guards.cblog %t/main.ll | FileCheck %s --check-prefix=MAIN
; RUN: opt -S -verify-each -passes=type-check-elimination -jeandle-vm-callback-log=%S/Inputs/raw-exact-klass-guards.cblog %t/callee-cc.ll | FileCheck %s --check-prefix=CC
; RUN: opt -S -verify-each -passes=type-check-elimination -jeandle-vm-callback-log=%S/Inputs/raw-exact-klass-guards.cblog %t/exact-helper-cc.ll | FileCheck %s --check-prefix=EXACTCC
;
; Klass 100 is a non-final base class and 200 is its subclass. Only the
; equality-success edge establishes exact 100 and rules out subtype 200.

;--- main.ll
declare hotspotcc ptr @jeandle.load_klass(ptr addrspace(1))
declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)
declare void @consume(i1)

; MAIN-LABEL: define i1 @eq_success_and_failure(
; MAIN: exact:
; MAIN-NEXT: ret i1 false
; MAIN: other:
; MAIN-NEXT: %maybe_subclass = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
; MAIN-NEXT: ret i1 %maybe_subclass
define i1 @eq_success_and_failure(ptr addrspace(1) nonnull %obj) {
entry:
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %guard = icmp eq ptr %klass, inttoptr (i64 100 to ptr)
  br i1 %guard, label %exact, label %other
exact:
  %base = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  %child = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %obj)
  ret i1 %child
other:
  %maybe_subclass = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %maybe_subclass
}

; MAIN-LABEL: define i1 @ne_swapped_success_and_failure(
; MAIN: exact:
; MAIN-NEXT: ret i1 true
; MAIN: other:
; MAIN-NEXT: %maybe_subclass = call hotspotcc i1 @jeandle.check_instanceof
; MAIN-NEXT: ret i1 %maybe_subclass
define i1 @ne_swapped_success_and_failure(ptr addrspace(1) nonnull %obj) {
entry:
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %guard = icmp ne ptr inttoptr (i64 100 to ptr), %klass
  br i1 %guard, label %other, label %exact
exact:
  %base = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %base
other:
  %maybe_subclass = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %maybe_subclass
}

; A call-site convention that differs from the helper declaration cannot
; establish a Java runtime Klass fact.
; MAIN-LABEL: define i1 @wrong_call_cc(
; MAIN: %klass = call ptr @jeandle.load_klass
; MAIN: exact:
; MAIN-NEXT: %result = call hotspotcc i1 @jeandle.check_instanceof
; MAIN-NEXT: ret i1 %result
define i1 @wrong_call_cc(ptr addrspace(1) nonnull %obj) {
entry:
  %klass = call ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %guard = icmp eq ptr %klass, inttoptr (i64 100 to ptr)
  br i1 %guard, label %exact, label %other
exact:
  %result = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %result
other:
  ret i1 false
}

; MAIN-LABEL: define i1 @bundled_klass_load(
; MAIN: %klass = call hotspotcc ptr @jeandle.load_klass{{.*}}[ "deopt"(i32 7) ]
; MAIN: exact:
; MAIN-NEXT: %result = call hotspotcc i1 @jeandle.check_instanceof
; MAIN-NEXT: ret i1 %result
define i1 @bundled_klass_load(ptr addrspace(1) nonnull %obj) {
entry:
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj) [ "deopt"(i32 7) ]
  %guard = icmp eq ptr %klass, inttoptr (i64 100 to ptr)
  br i1 %guard, label %exact, label %other
exact:
  %result = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %result
other:
  ret i1 false
}

; MAIN-LABEL: define i1 @non_equality_predicate(
; MAIN: selected:
; MAIN-NEXT: %result = call hotspotcc i1 @jeandle.check_instanceof
; MAIN-NEXT: ret i1 %result
define i1 @non_equality_predicate(ptr addrspace(1) nonnull %obj) {
entry:
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %guard = icmp ult ptr %klass, inttoptr (i64 100 to ptr)
  br i1 %guard, label %selected, label %other
selected:
  %result = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %result
other:
  ret i1 false
}

; MAIN-LABEL: define i1 @different_object(
; MAIN: exact:
; MAIN-NEXT: %result = call hotspotcc i1 @jeandle.check_instanceof
; MAIN-NEXT: ret i1 %result
define i1 @different_object(ptr addrspace(1) nonnull %obj, ptr addrspace(1) nonnull %other_obj) {
entry:
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %other_obj)
  %guard = icmp eq ptr %klass, inttoptr (i64 100 to ptr)
  br i1 %guard, label %exact, label %other
exact:
  %result = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %result
other:
  ret i1 false
}

; Defined freezes preserve the oop, loaded Klass and comparison identities.
; MAIN-LABEL: define i1 @defined_freezes(
; MAIN: exact:
; MAIN-NEXT: ret i1 false
define i1 @defined_freezes(ptr addrspace(1) noundef nonnull %obj) {
entry:
  %frozen_obj = freeze ptr addrspace(1) %obj
  %klass = call hotspotcc noundef ptr @jeandle.load_klass(ptr addrspace(1) %frozen_obj)
  %frozen_klass = freeze ptr %klass
  %expected = freeze ptr inttoptr (i64 100 to ptr)
  %guard = icmp eq ptr %frozen_klass, %expected
  %frozen_guard = freeze i1 %guard
  br i1 %frozen_guard, label %exact, label %other
exact:
  %result = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %obj)
  ret i1 %result
other:
  ret i1 false
}

; Without noundef the loaded Klass may be poison or undef. Its freeze can
; produce a value unrelated to the object, so the original type is unknown.
; MAIN-LABEL: define i1 @possibly_undefined_klass_freeze(
; MAIN: %frozen = freeze ptr %klass
; MAIN: exact:
; MAIN-NEXT: %result = call hotspotcc i1 @jeandle.check_instanceof
; MAIN-NEXT: ret i1 %result
define i1 @possibly_undefined_klass_freeze(ptr addrspace(1) nonnull %obj) {
entry:
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %frozen = freeze ptr %klass
  %guard = icmp eq ptr %frozen, inttoptr (i64 100 to ptr)
  br i1 %guard, label %exact, label %other
exact:
  %result = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %result
other:
  ret i1 false
}

; Freezing the potentially undefined boolean also loses the edge proof.
; MAIN-LABEL: define i1 @possibly_undefined_condition_freeze(
; MAIN: %frozen = freeze i1 %guard
; MAIN: exact:
; MAIN-NEXT: %result = call hotspotcc i1 @jeandle.check_instanceof
; MAIN-NEXT: ret i1 %result
define i1 @possibly_undefined_condition_freeze(ptr addrspace(1) nonnull %obj) {
entry:
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %guard = icmp eq ptr %klass, inttoptr (i64 100 to ptr)
  %frozen = freeze i1 %guard
  br i1 %frozen, label %exact, label %other
exact:
  %result = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %result
other:
  ret i1 false
}

; MAIN-LABEL: define i1 @poison_expected_freeze(
; MAIN: %expected = freeze ptr poison
; MAIN: exact:
; MAIN-NEXT: %result = call hotspotcc i1 @jeandle.check_instanceof
; MAIN-NEXT: ret i1 %result
define i1 @poison_expected_freeze(ptr addrspace(1) nonnull %obj) {
entry:
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %expected = freeze ptr poison
  %guard = icmp eq ptr %klass, %expected
  br i1 %guard, label %exact, label %other
exact:
  %result = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %result
other:
  ret i1 false
}

; MAIN-LABEL: define i1 @undef_expected_freeze(
; MAIN: %expected = freeze ptr undef
; MAIN: exact:
; MAIN-NEXT: %result = call hotspotcc i1 @jeandle.check_instanceof
; MAIN-NEXT: ret i1 %result
define i1 @undef_expected_freeze(ptr addrspace(1) nonnull %obj) {
entry:
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %expected = freeze ptr undef
  %guard = icmp eq ptr %klass, %expected
  br i1 %guard, label %exact, label %other
exact:
  %result = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %result
other:
  ret i1 false
}

; The exact fact is valid in one arm, but not after rejoining both outcomes.
; MAIN-LABEL: define i1 @rejoin_both_edges(
; MAIN: exact:
; MAIN-NEXT: call void @consume(i1 true)
; MAIN-NEXT: br label %merge
; MAIN: merge:
; MAIN-NEXT: %result = call hotspotcc i1 @jeandle.check_instanceof
; MAIN-NEXT: ret i1 %result
define i1 @rejoin_both_edges(ptr addrspace(1) nonnull %obj) {
entry:
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %guard = icmp eq ptr %klass, inttoptr (i64 100 to ptr)
  br i1 %guard, label %exact, label %other
exact:
  %local = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  call void @consume(i1 %local)
  br label %merge
other:
  br label %merge
merge:
  %result = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %result
}

; MAIN-LABEL: define i1 @duplicate_successor(
; MAIN: merge:
; MAIN-NEXT: %result = call hotspotcc i1 @jeandle.check_instanceof
; MAIN-NEXT: ret i1 %result
define i1 @duplicate_successor(ptr addrspace(1) nonnull %obj) {
entry:
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %guard = icmp eq ptr %klass, inttoptr (i64 100 to ptr)
  br i1 %guard, label %merge, label %merge
merge:
  %result = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %result
}

; The latch is guarded, while the header's first iteration is unguarded.
; MAIN-LABEL: define i1 @loop_latch_fact_stays_local(
; MAIN: header:
; MAIN-NEXT: %result = call hotspotcc i1 @jeandle.check_instanceof
; MAIN: exact_latch:
; MAIN-NEXT: call void @consume(i1 false)
; MAIN-NEXT: br label %header
; MAIN: done:
; MAIN-NEXT: ret i1 %result
define i1 @loop_latch_fact_stays_local(ptr addrspace(1) nonnull %obj) {
entry:
  br label %header
header:
  %result = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %guard = icmp eq ptr %klass, inttoptr (i64 100 to ptr)
  br i1 %guard, label %exact_latch, label %done
exact_latch:
  %child = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %obj)
  call void @consume(i1 %child)
  br label %header
done:
  ret i1 %result
}

; An entry guard, unlike a latch-only guard, constrains every loop iteration.
; MAIN-LABEL: define i1 @entry_guarded_loop(
; MAIN: header:
; MAIN-NEXT: call void @consume(i1 false)
; MAIN-NEXT: br i1 %again, label %header, label %done
; MAIN: done:
; MAIN-NEXT: ret i1 false
define i1 @entry_guarded_loop(ptr addrspace(1) nonnull %obj, i1 %again) {
entry:
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %guard = icmp eq ptr %klass, inttoptr (i64 100 to ptr)
  br i1 %guard, label %header, label %done
header:
  %child = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 200 to ptr), ptr addrspace(1) %obj)
  call void @consume(i1 %child)
  br i1 %again, label %header, label %done
done:
  ret i1 false
}

!java-method-compilation = !{}

;--- callee-cc.ll
declare ptr @jeandle.load_klass(ptr addrspace(1))
declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)

; Matching call and callee conventions are insufficient if neither is the
; Hotspot convention required by the runtime helper contract.
; CC-LABEL: define i1 @non_hotspot_callee(
; CC: %klass = call ptr @jeandle.load_klass
; CC: exact:
; CC-NEXT: %result = call hotspotcc i1 @jeandle.check_instanceof
; CC-NEXT: ret i1 %result
define i1 @non_hotspot_callee(ptr addrspace(1) nonnull %obj) {
entry:
  %klass = call ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %guard = icmp eq ptr %klass, inttoptr (i64 100 to ptr)
  br i1 %guard, label %exact, label %other
exact:
  %result = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %result
other:
  ret i1 false
}

; CC-LABEL: define i1 @wrong_callee_cc(
; CC: %klass = call hotspotcc ptr @jeandle.load_klass
; CC: exact:
; CC-NEXT: %result = call hotspotcc i1 @jeandle.check_instanceof
; CC-NEXT: ret i1 %result
define i1 @wrong_callee_cc(ptr addrspace(1) nonnull %obj) {
entry:
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %guard = icmp eq ptr %klass, inttoptr (i64 100 to ptr)
  br i1 %guard, label %exact, label %other
exact:
  %result = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %result
other:
  ret i1 false
}

!java-method-compilation = !{}

;--- exact-helper-cc.ll
declare hotspotcc ptr @jeandle.load_klass(ptr addrspace(1))
declare i1 @jeandle.check_exact_klass(ptr, ptr)
declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)

; A correctly formed Klass load does not make a differently specified exact
; check helper eligible to establish the runtime type.
; EXACTCC-LABEL: define i1 @non_hotspot_exact_helper(
; EXACTCC: %klass = call hotspotcc ptr @jeandle.load_klass
; EXACTCC: %guard = call i1 @jeandle.check_exact_klass
; EXACTCC: exact:
; EXACTCC-NEXT: %result = call hotspotcc i1 @jeandle.check_instanceof
; EXACTCC-NEXT: ret i1 %result
define i1 @non_hotspot_exact_helper(ptr addrspace(1) nonnull %obj) {
entry:
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %guard = call i1 @jeandle.check_exact_klass(ptr %klass, ptr inttoptr (i64 100 to ptr))
  br i1 %guard, label %exact, label %other
exact:
  %result = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 100 to ptr), ptr addrspace(1) %obj)
  ret i1 %result
other:
  ret i1 false
}

!java-method-compilation = !{}
