; RUN: opt -S -verify-each -passes='require<partial-escape-analysis>,partial-escape-transform' -jeandle-vm-callback-log=%S/Inputs/822_publication_owners.cblog %s | FileCheck %s
; RUN: opt -S -verify-each -passes='partial-escape-iterative' -jeandle-pea-iterations=8 -jeandle-vm-callback-log=%S/Inputs/822_publication_owners.cblog %s | FileCheck %s
;
; Removing an owner is an entry-wise transaction, including late ineligibility.
target datalayout = "e-p:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.membar_replay_publish(i32, ...)
declare hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1))
declare void @sink_i1(i1)

; CHECK-LABEL: define void @mixed(
; CHECK-NOT: @jeandle.new_instance
; CHECK: call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 2, ptr addrspace(1){{[^,%]*}} %real, i32 2, ptr addrspace(1){{[^,%]*}} null, i32 1)
; CHECK-NEXT: ret void
define void @mixed(ptr addrspace(1) %real) gc "hotspotgc" {
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 4, ptr addrspace(1) %a, i32 1, ptr addrspace(1) %real, i32 2, ptr addrspace(1) null, i32 1, ptr addrspace(1) %b, i32 3)
  ret void
}

; CHECK-LABEL: define void @late_ineligible(
; CHECK: %bad = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: %good =
; CHECK: call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 1, ptr addrspace(1){{[^,%]*}} %bad, i32 2)
; CHECK-NEXT: %value = call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %bad)
; CHECK-NEXT: call void @sink_i1(i1 %value)
; CHECK-NEXT: ret void
define void @late_ineligible() gc "hotspotgc" {
  %bad = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 7777 to ptr), i32 24, i1 false)
  %good = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 2, ptr addrspace(1) %bad, i32 2, ptr addrspace(1) %good, i32 1)
  %value = call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %bad)
  call void @sink_i1(i1 %value)
  ret void
}

; CHECK-LABEL: define void @interior(
; CHECK: %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: %b =
; CHECK: call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 1, ptr addrspace(1){{[^,%]*}} %field, i32 1)
; CHECK-NEXT: ret void
define void @interior() gc "hotspotgc" {
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  %field = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 2, ptr addrspace(1) %field, i32 1, ptr addrspace(1) %b, i32 2)
  ret void
}
; CHECK-LABEL: define ptr addrspace(1) @last_owner_disappears(
; CHECK: %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: %b =
; CHECK: store atomic i32 %value,
; CHECK-NEXT: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %a)
; CHECK-NEXT: ret ptr addrspace(1) %a
define ptr addrspace(1) @last_owner_disappears(i32 %value) gc "hotspotgc" {
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %value, ptr addrspace(1) %af unordered, align 4
  call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 2, ptr addrspace(1) %a, i32 1, ptr addrspace(1) %b, i32 2)
  ret ptr addrspace(1) %a
}

!java-method-compilation = !{}
