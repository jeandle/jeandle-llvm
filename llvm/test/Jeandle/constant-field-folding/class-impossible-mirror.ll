; Copyright (c) 2026, The Jeandle-LLVM Authors. All Rights Reserved.
;
; Part of the Jeandle-LLVM project, under the Apache License, Version 2.0 with LLVM Exceptions.
; See https://llvm.org/LICENSE.txt for license information.
; SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
;
; RUN: opt -S -verify-each -passes='constant-field-folding,dce' -jeandle-vm-callback-log=%S/Inputs/class-impossible-mirror.cblog %s | FileCheck %s

@AccessFlags.jvm_acc_abstract = private constant i32 1024
@AccessFlags.jvm_acc_interface = private constant i32 512
declare hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1)) memory(read) nounwind willreturn
declare hotspotcc ptr @jeandle.load_klass(ptr addrspace(1)) memory(read) nounwind willreturn
@oop_handle_Mirror_0 = external global ptr addrspace(1)
; CHECK-LABEL: define i1 @interface(
; CHECK-NOT: @jeandle.get_class
; CHECK-NEXT: ret i1 false
define i1 @interface(ptr addrspace(1) nonnull %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %c = load ptr addrspace(1), ptr @oop_handle_Mirror_0
  %r = icmp eq ptr addrspace(1) %m, %c
  ret i1 %r
}
@oop_handle_Mirror_1 = external global ptr addrspace(1)
; CHECK-LABEL: define i1 @abstract(
; CHECK-NOT: @jeandle.get_class
; CHECK-NEXT: ret i1 false
define i1 @abstract(ptr addrspace(1) nonnull %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %c = load ptr addrspace(1), ptr @oop_handle_Mirror_1
  %r = icmp eq ptr addrspace(1) %m, %c
  ret i1 %r
}
@oop_handle_Mirror_2 = external global ptr addrspace(1)
; CHECK-LABEL: define i1 @array(
; CHECK: icmp eq ptr {{.*}}, inttoptr (i64 300 to ptr)
define i1 @array(ptr addrspace(1) nonnull %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %c = load ptr addrspace(1), ptr @oop_handle_Mirror_2
  %r = icmp eq ptr addrspace(1) %m, %c
  ret i1 %r
}
@oop_handle_Mirror_3 = external global ptr addrspace(1)
; CHECK-LABEL: define i1 @unknown_layout(
; CHECK: icmp eq ptr {{.*}}, inttoptr (i64 400 to ptr)
define i1 @unknown_layout(ptr addrspace(1) nonnull %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %c = load ptr addrspace(1), ptr @oop_handle_Mirror_3
  %r = icmp eq ptr addrspace(1) %m, %c
  ret i1 %r
}
@oop_handle_Mirror_4 = external global ptr addrspace(1)
; CHECK-LABEL: define i1 @concrete(
; CHECK: icmp eq ptr {{.*}}, inttoptr (i64 500 to ptr)
define i1 @concrete(ptr addrspace(1) nonnull %obj) {
  %m = call hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %obj)
  %c = load ptr addrspace(1), ptr @oop_handle_Mirror_4
  %r = icmp eq ptr addrspace(1) %m, %c
  ret i1 %r
}
!java-method-compilation = !{}
