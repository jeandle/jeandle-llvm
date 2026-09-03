; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Multi-scope descriptors, cross-scope CYCLE: two virtual objects reference
; EACH OTHER through their fields (%a.f = %b, %b.f = %a) and are referenced
; from DIFFERENT scopes: %a by the ROOT scope's locals, %b by the INNERMOST
; scope's locals. Both descriptors go into the ROOT scope's VO section
; (after the first duplicated-BCI pair); each VO's T_OBJECT field becomes a
; VORef field naming the OTHER object's vo-id (vo-ids follow allocation
; order: %a=0, %b=1) — the cyclic structure is fully expressible in the
; deopt-point-level pool.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32)
declare i32 @__gxx_personality_v0(...)

define void @multiscope_cycle(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 16, i1 false)
       to label %n1 unwind label %u
n1:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 16, i1 false)
       to label %n2 unwind label %u
n2:
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic ptr addrspace(1) %b, ptr addrspace(1) %af unordered, align 8
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %bf unordered, align 8
  ; Two-scope bundle: ROOT scope (bci 5, preceded by its should_reexecute
  ; i64) local 0 is %a; INNERMOST scope
  ; (bci 9) local 0 is %b. (i64 393233 = MethodType marker pair encoding:
  ; (6<<16)|T_METADATA(17).)
  call void @sink(i32 %x)
       [ "deopt"(i64 0, i32 5, i32 5, i64 12, ptr addrspace(1) %a,
                 i64 393233, i64 777,
                 i64 1, i32 9, i32 9, i64 12, ptr addrspace(1) %b) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both %a and %b are NeverEscapes: eliminated and described right AFTER THE
; ROOT SCOPE PREFIX (should_reexecute i64 0 + duplicated-BCI pair
; i32 5, i32 5). Descriptor emission order follows the slot
; scan order (root scope's referenced VO first), NOT the vo-id order:
;   %a (vo_id=0): header (0<<32)|(4<<16)|12 = 262156; klass 100; field_count
;     1; field (offset 8, VORef field, T_OBJECT): (8<<32)|(8<<16)|12 =
;     34360262668 -> i32 vo-id 1 (%b).
;   %b (vo_id=1): header (1<<32)|(4<<16)|12 = 4295229452; klass 100;
;     field_count 1; same VORef field encoding -> i32 vo-id 0 (%a).
; The ROOT-scope slot (%a) becomes VORefLocalType vo_id=0:
; (0<<32)|(8<<16)|12 = 524300, then i32 0; the INNERMOST slot (%b) becomes
; VORefLocalType vo_id=1: (1<<32)|(8<<16)|12 = 4295491596, then i32 1.
; CHECK-LABEL: define void @multiscope_cycle(
; CHECK-NOT: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call void @sink(i32 %x)
; CHECK-SAME: [ "deopt"(i64 0, i32 5, i32 5, i64 262156, i64 100, i32 1, i64 34360262668, i32 1, i64 4295229452, i64 100, i32 1, i64 34360262668, i32 0, i64 524300, i32 0, i64 393233, i64 777, i64 1, i32 9, i32 9, i64 4295491596, i32 1) ]
; CHECK-NOT: poison

!java-method-compilation = !{}
