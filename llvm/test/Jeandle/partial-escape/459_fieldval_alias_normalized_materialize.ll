; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Dangling field snapshot.
; %b is NeverEscapes; %v = load %b.f8 folds to %x (ReplaceLoad RAUWs + erases
; %v in Pass 1, BEFORE the Materialize applies). The store of %v into %a.f8
; must be tracked as Scalar(%x) — the scalar-alias-normalized terminal — not
; as the folded %v, or applyMaterialize would replay a freed value.
; o.f = p.g shape with a materialization (escape) at the end.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @field_value_producer_folded(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 24, i1 false)
       to label %na unwind label %u
na:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 24, i1 false)
       to label %nb unwind label %u
nb:
  %b8 = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 %x, ptr addrspace(1) %b8 unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %b8 unordered, align 4
  %a8 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 %v, ptr addrspace(1) %a8 unordered, align 4
  call void @sink(ptr addrspace(1) %a)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; %a is PartiallyEscapes: OrigAlloc retained, field replayed BEFORE the sink
; with the ORIGINAL value %x (never the erased %v). %b is NeverEscapes and
; eliminated entirely (its store/load fold away).
; CHECK-LABEL: define void @field_value_producer_folded(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 11111 to ptr), i32 24, i1 false)
; CHECK-NOT: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: store atomic i32 %x, ptr addrspace(1) %pea.matslot unordered, align 4
; CHECK: call void @sink(ptr addrspace(1) %a)
; CHECK-NOT: poison

!java-method-compilation = !{}
