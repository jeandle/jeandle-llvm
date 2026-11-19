; Copyright (c) 2026, The Jeandle-LLVM Authors. All Rights Reserved.
;
; Part of the Jeandle-LLVM project, under the Apache License, Version 2.0 with LLVM Exceptions.
; See https://llvm.org/LICENSE.txt for license information.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; RUN: opt -S -verify-each -passes='constant-field-folding,instcombine,simplifycfg,dce' -jeandle-vm-callback-log=%S/Inputs/class-dynamic-mirror-origin.cblog %s | FileCheck %s
; RUN: sed '/^@java_lang_Class.klass =/d' %s | opt -S -verify-each -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/class-dynamic-mirror-origin.cblog | FileCheck %s --check-prefix=MISSING
; RUN: sed 's/declare hotspotcc ptr @jeandle.load_mirror_klass/declare ptr @jeandle.load_mirror_klass/' %s | opt -S -verify-each -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/class-dynamic-mirror-origin.cblog | FileCheck %s --check-prefix=MISSING
; MISSING-LABEL: define i1 @known_class(
; MISSING: call hotspotcc ptr addrspace(1) @jeandle.get_class
; MISSING: icmp eq ptr addrspace(1)


@java_lang_Class.klass = private constant i64 900
declare hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1)) memory(read) nounwind willreturn
declare hotspotcc ptr @jeandle.load_klass(ptr addrspace(1)) memory(read) nounwind willreturn
declare hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1)) memory(read) nounwind willreturn

; A primitive dynamic target has null mirror Klass, unlike every getClass result.
; CHECK-LABEL: define i1 @known_class(
; CHECK-NOT: @jeandle.get_class
; CHECK: [[K:%.*]] = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1){{( nonnull)?}} %obj)
; CHECK: [[T:%.*]] = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1){{( nonnull)?}} %target)
; CHECK: icmp eq ptr [[K]], [[T]]
; CHECK-NOT: @jeandle.get_class
; CHECK: ret i1
define i1 @known_class(ptr addrspace(1) nonnull %obj, ptr addrspace(1) nonnull "java-klass"="900" %target) {
  %mirror = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = icmp eq ptr addrspace(1) %mirror, %target
  ret i1 %r
}

; CHECK-LABEL: define i1 @unknown_object(
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.get_class
; CHECK: icmp eq ptr addrspace(1)
define i1 @unknown_object(ptr addrspace(1) nonnull %obj, ptr addrspace(1) nonnull %target) {
  %mirror = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = icmp eq ptr addrspace(1) %mirror, %target
  ret i1 %r
}

; CHECK-LABEL: define i1 @nullable_class(
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.get_class
; CHECK: icmp eq ptr addrspace(1)
define i1 @nullable_class(ptr addrspace(1) nonnull %obj, ptr addrspace(1) "java-klass"="900" %target) {
  %mirror = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = icmp eq ptr addrspace(1) %mirror, %target
  ret i1 %r
}

; A primitive dynamic target has null mirror Klass, unlike every getClass result.
; CHECK-LABEL: define i1 @known_class_ne(
; CHECK-NOT: @jeandle.get_class
; CHECK: [[K:%.*]] = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1){{( nonnull)?}} %obj)
; CHECK: [[T:%.*]] = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1){{( nonnull)?}} %target)
; CHECK: icmp ne ptr [[K]], [[T]]
; CHECK-NOT: @jeandle.get_class
; CHECK: ret i1
define i1 @known_class_ne(ptr addrspace(1) nonnull %obj, ptr addrspace(1) nonnull "java-klass"="900" %target) {
  %mirror = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = icmp ne ptr addrspace(1) %mirror, %target
  ret i1 %r
}


; A primitive dynamic target has null mirror Klass, unlike every getClass result.
; CHECK-LABEL: define i1 @swapped_class(
; CHECK-NOT: @jeandle.get_class
; CHECK: [[K:%.*]] = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1){{( nonnull)?}} %obj)
; CHECK: [[T:%.*]] = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1){{( nonnull)?}} %target)
; CHECK: icmp eq ptr [[K]], [[T]]
; CHECK-NOT: @jeandle.get_class
; CHECK: ret i1
define i1 @swapped_class(ptr addrspace(1) nonnull %obj, ptr addrspace(1) nonnull "java-klass"="900" %target) {
  %mirror = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %r = icmp eq ptr addrspace(1) %target, %mirror
  ret i1 %r
}


; A dominating branch proves the target non-null at this comparison.
; CHECK-LABEL: define i1 @branch_nonnull(
; CHECK-NOT: @jeandle.get_class
; CHECK: call hotspotcc ptr @jeandle.load_klass
; CHECK-NOT: @jeandle.get_class
; CHECK: call hotspotcc ptr @jeandle.load_mirror_klass
; CHECK-NOT: @jeandle.get_class
; CHECK: icmp ne ptr
; CHECK-NOT: @jeandle.get_class
; CHECK: }
define i1 @branch_nonnull(ptr addrspace(1) nonnull %obj, ptr addrspace(1) "java-klass"="900" %target) {
entry:
  %present = icmp ne ptr addrspace(1) %target, null
  br i1 %present, label %compare, label %absent
compare:
  %mirror = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %wrapped = freeze ptr addrspace(1) %mirror
  %r = icmp ne ptr addrspace(1) %target, %wrapped
  ret i1 %r
absent:
  ret i1 false
}

!java-method-compilation = !{}
