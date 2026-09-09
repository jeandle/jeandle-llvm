; RUN: opt -S -verify-each \
; RUN:   -passes="partial-escape-iterative,partial-escape-iterative" \
; RUN:   -jeandle-pea-iterations=8 %s | FileCheck %s --check-prefix=IR

; A Case-C synthetic VO described only in a deopt bundle (NeverEscapes) must
; stay DESCRIBED — and not churn — across the outer iterative fixpoint. After
; the first iteration the source allocations are gone, so later iterations are
; a no-op and the descriptor (with the merged field value) survives unchanged.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1) nounwind
declare void @safepoint()

define void @synthetic_described_iter(i1 %choose) gc "hotspotgc" {
entry:
  br i1 %choose, label %left, label %right
left:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 70401 to ptr), i32 24, i1 false) [ "deopt"(i32 704011) ]
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 41, ptr addrspace(1) %af unordered, align 4
  br label %merge
right:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 70401 to ptr), i32 24, i1 false) [ "deopt"(i32 704012) ]
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 42, ptr addrspace(1) %bf unordered, align 4
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  call void @safepoint()
      [ "deopt"(i32 88, i32 88, i64 12, ptr addrspace(1) %p) ]
  ret void
}

; IR-LABEL: define void @synthetic_described_iter(
; Sources eliminated; no allocations, no replay.
; IR-NOT: call {{.*}}@jeandle.new_instance
; IR-NOT: store atomic
; The merged field value (a select over the branch values) feeds the descriptor.
; IR: = select i1 %choose, i32 41, i32 42
; IR: call void @safepoint() [ "deopt"(
; IR-SAME: i32 88, i32 88,
; The root synthetic is assigned dense wire id 0: klass 70401, field_count 1,
; offset 8 = merged value.
; IR-SAME: i64 262156, i64 70401, i32 1,
; IR-SAME: i64 34359738378, i32 %{{[^,]+}},
; %p slot -> VORef wire id 0.
; IR-SAME: i64 524300, i32 0) ]
; IR-NOT: poison

!java-method-compilation = !{}
