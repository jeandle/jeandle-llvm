; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Multi-scope descriptors, sibling VOs at one safepoint: TWO independent
; virtual objects are referenced by the SAME bundle from DIFFERENT scopes —
; %o (allocated first, klass 100) by the ROOT scope's locals, %p (klass 200)
; by the INNERMOST scope's locals. Both are described in the ROOT scope's
; VO section (after the first duplicated-BCI pair) and each referencing
; slot is rewritten to a VORef by its own vo-id (vo-ids follow allocation
; order: %o=0, %p=1).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32)
declare i32 @__gxx_personality_v0(...)

define void @multiscope_siblings(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 16, i1 false)
       to label %n1 unwind label %u
n1:
  %p = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 200 to ptr), i32 16, i1 false)
       to label %n2 unwind label %u
n2:
  %of = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %pf = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  store atomic i32 %x, ptr addrspace(1) %of unordered, align 4
  store atomic i32 %x, ptr addrspace(1) %pf unordered, align 4
  ; Two-scope bundle: ROOT scope (bci 5, preceded by its should_reexecute
  ; i64) local 0 is %o; INNERMOST scope
  ; (bci 9) local 0 is %p. (i64 393233 = MethodType marker pair encoding:
  ; (6<<16)|T_METADATA(17).)
  call void @sink(i32 %x)
       [ "deopt"(i64 0, i32 5, i32 5, i64 12, ptr addrspace(1) %o,
                 i64 393233, i64 777,
                 i64 1, i32 9, i32 9, i64 12, ptr addrspace(1) %p) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both %o and %p are NeverEscapes: eliminated and described right AFTER THE
; ROOT SCOPE PREFIX (should_reexecute i64 0 + duplicated-BCI pair
; i32 5, i32 5). Descriptor emission order follows the slot
; scan order (root scope's referenced VO first):
;   %o (vo_id=0): header (0<<32)|(4<<16)|12 = 262156; klass 100; field_count
;     1; field (offset 8, LocalType/T_INT): (8<<32)|10 = 34359738378 -> %x.
;   %p (vo_id=1): header (1<<32)|(4<<16)|12 = 4295229452; klass 200;
;     field_count 1; same field encoding -> %x.
; The ROOT-scope slot (%o) becomes VORefLocalType vo_id=0:
; (0<<32)|(8<<16)|12 = 524300, then i32 0; the INNERMOST slot (%p) becomes
; VORefLocalType vo_id=1: (1<<32)|(8<<16)|12 = 4295491596, then i32 1.
; CHECK-LABEL: define void @multiscope_siblings(
; CHECK-NOT: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call void @sink(i32 %x)
; CHECK-SAME: [ "deopt"(i64 0, i32 5, i32 5, i64 262156, i64 100, i32 1, i64 34359738378, i32 %x, i64 4295229452, i64 200, i32 1, i64 34359738378, i32 %x, i64 524300, i32 0, i64 393233, i64 777, i64 1, i32 9, i32 9, i64 4295491596, i32 1) ]
; CHECK-NOT: poison

!java-method-compilation = !{}
