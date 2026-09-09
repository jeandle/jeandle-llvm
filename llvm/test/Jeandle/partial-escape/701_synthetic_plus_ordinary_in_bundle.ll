; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s --check-prefix=IR

; A Case-C synthetic VO and an independent ordinary VO both referenced in one
; safepoint's deopt bundle are each DESCRIBED by their own descriptor, and each
; bundle slot is rewritten to a VORef to its own VO — no cross-rewiring. Both
; escape only via deopt, so every source allocation is eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1) nounwind
declare void @safepoint()

define void @synthetic_plus_ordinary(i1 %c) gc "hotspotgc" {
entry:
  %o = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 70101 to ptr), i32 24, i1 false) [ "deopt"(i32 701011) ]
  %of = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 7, ptr addrspace(1) %of unordered, align 4
  br i1 %c, label %left, label %right
left:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 70102 to ptr), i32 24, i1 false) [ "deopt"(i32 701012) ]
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 41, ptr addrspace(1) %af unordered, align 4
  br label %merge
right:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 70102 to ptr), i32 24, i1 false) [ "deopt"(i32 701013) ]
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 42, ptr addrspace(1) %bf unordered, align 4
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  call void @safepoint()
      [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %o,
               i64 4294967308, ptr addrspace(1) %p) ]
  ret void
}

; IR-LABEL: define void @synthetic_plus_ordinary(
; All three source allocations eliminated; no materialization replay.
; IR-NOT: call {{.*}}@jeandle.new_instance
; IR-NOT: store atomic
; IR-NOT: pea.matslot
; IR: %[[PF:pea.casec.field.phi]] = phi i32 [ 41, %left ], [ 42, %right ]
; IR: call void @safepoint() [ "deopt"(
; IR-SAME: i32 99, i32 99,
; Descriptor for the ordinary VO %o (vo_id=0): klass 70101, field_count 1,
; field offset 8 = 7.
; IR-SAME: i64 262156, i64 70101, i32 1,
; IR-SAME: i64 34359738378, i32 7,
; Descriptor for the synthetic %p (wire id 1): klass 70102, field_count 1,
; field offset 8 = merged field PHI.
; IR-SAME: i64 4295229452, i64 70102, i32 1,
; IR-SAME: i64 34359738378, i32 %[[PF]],
; %o slot -> VORef wire id 0; %p slot -> VORef wire id 1.
; IR-SAME: i64 524300, i32 0,
; IR-SAME: i64 4295491596, i32 1) ]
; IR-NOT: poison

!java-method-compilation = !{}
