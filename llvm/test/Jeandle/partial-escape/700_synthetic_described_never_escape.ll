; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s --check-prefix=IR

; A Case-C synthetic object referenced ONLY in a safepoint's deopt bundle (no
; real escape) is DESCRIBED there (a VO descriptor + a VORef slot) rather than
; materialized, and its source allocations are eliminated. A synthetic VO is
; treated identically to a normal VO in deopt: a virtual object that escapes
; only via a deopt frame state is encoded as a VO descriptor and reallocated
; by the runtime at deopt.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1) nounwind
declare void @safepoint()

define void @synthetic_described_never_escape(i1 %choose) gc "hotspotgc" {
entry:
  br i1 %choose, label %left, label %right
left:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 70001 to ptr), i32 24, i1 false) [ "deopt"(i32 700011) ]
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 41, ptr addrspace(1) %af unordered, align 4
  br label %merge
right:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 70001 to ptr), i32 24, i1 false) [ "deopt"(i32 700012) ]
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 42, ptr addrspace(1) %bf unordered, align 4
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  call void @safepoint()
      [ "deopt"(i32 88, i32 88, i64 12, ptr addrspace(1) %p) ]
  ret void
}

; IR-LABEL: define void @synthetic_described_never_escape(
; Source allocations are eliminated: the synthetic escapes only via deopt, so
; its sources need not remain real, and there is no materialization replay.
; IR-NOT: call {{.*}}@jeandle.new_instance
; IR-NOT: store atomic
; IR-NOT: pea.matslot
; The merged field value (a PHI over the two branch values) feeds the VO
; descriptor at the safepoint.
; IR: %[[F:pea.casec.field.phi]] = phi i32 [ 41, %left ], [ 42, %right ]
; IR: call void @safepoint() [ "deopt"(
; IR-SAME: i32 88, i32 88,
; VO descriptor: header (wire id 0, ScalarValueType, T_OBJECT), klass 70001,
; field_count 1, field offset 8 (LocalType, T_INT) = merged field value.
; IR-SAME: i64 262156, i64 70001, i32 1,
; IR-SAME: i64 34359738378, i32 %[[F]],
; The %p slot is rewritten to a VORefLocalType reference (wire id 0).
; IR-SAME: i64 524300, i32 0) ]
; IR-NOT: poison

!java-method-compilation = !{}
