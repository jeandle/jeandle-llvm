; RUN: opt -S -verify-each -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/frozen-oop-identity.cblog %s | FileCheck %s

@oop_handle_Test_0 = external dso_local global ptr addrspace(1)
declare hotspotcc ptr @jeandle.load_klass(ptr addrspace(1))

define hotspotcc {ptr addrspace(1), ptr} @keep_frozen_identity() #0 gc "hotspotgc" {
  %obj = load ptr addrspace(1), ptr @oop_handle_Test_0
  %poison_obj = select i1 poison, ptr addrspace(1) %obj, ptr addrspace(1) %obj
  %frozen = freeze ptr addrspace(1) %poison_obj
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %frozen)
  %p = insertvalue {ptr addrspace(1), ptr} poison, ptr addrspace(1) %frozen, 0
  %pair = insertvalue {ptr addrspace(1), ptr} %p, ptr %klass, 1
  ret {ptr addrspace(1), ptr} %pair
}
; CHECK-LABEL: @keep_frozen_identity(
; CHECK: %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %frozen)
; CHECK: %pair = insertvalue {{.*}} ptr %klass, 1

define hotspotcc ptr @fold_defined_identity() #0 gc "hotspotgc" {
  %obj = load ptr addrspace(1), ptr @oop_handle_Test_0, !noundef !0
  %frozen = freeze ptr addrspace(1) %obj
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %frozen)
  ret ptr %klass
}
; CHECK-LABEL: @fold_defined_identity(
; CHECK: ret ptr inttoptr (i64 123456 to ptr)

attributes #0 = { "java-method"="0" }
!0 = !{}
!java-method-compilation = !{}
