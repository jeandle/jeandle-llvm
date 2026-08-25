; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Field-PHI producer under materialize-at-use: o.f = p.g where p.g is a
; MERGE field-PHI (analyzer-built, owned by p's CreatePHI effect). p then
; escapes via a DERIVED pointer (%gp) — the generic escape path
; MATERIALIZES p at the call instead of marking it ineligible, so p's
; CreatePHI effect survives and the field-PHI is replayed onto p's
; OrigAlloc before the call. o likewise materializes at its escape,
; replaying o.f's tracked store of the folded field-PHI. Both allocations
; stay real, the PHI has live uses in the two replays, no orphan PHI, no
; poison. The commit availability sweep does not fire on this shape: the
; derived-pointer escape materializes rather than bails.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare void @sinkp(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @phi_producer_dropped(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %p = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 16, i1 false)
       to label %np unwind label %u
np:
  %pg = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  br i1 %c, label %t, label %f
t:
  store atomic i32 1, ptr addrspace(1) %pg unordered, align 4
  br label %m
f:
  store atomic i32 2, ptr addrspace(1) %pg unordered, align 4
  br label %m
m:
  ; p.g is a merge field-PHI here; %lg folds to it.
  %lg = load atomic i32, ptr addrspace(1) %pg unordered, align 4
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 200 to ptr), i32 16, i1 false)
       to label %no unwind label %u
no:
  %of = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %lg, ptr addrspace(1) %of unordered, align 4
  ; derived-pointer escape of p -> p materializes at the call (CreatePHI
  ; survives; the field-PHI is replayed onto OrigAlloc).
  %gp = getelementptr inbounds i8, ptr addrspace(1) %p, i64 4
  call void @sinkp(ptr addrspace(1) %gp)
  ; o escapes: its tracked o.f store replays the folded field-PHI.
  call void @sink(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both allocations stay real; the branch stores fold into %pea.field.phi;
; each escape replays its tracked store onto the OrigAlloc immediately
; before the call; no orphan PHI, no poison.
; CHECK-LABEL: define void @phi_producer_dropped(
; CHECK: %p = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 100 to ptr), i32 16, i1 false)
; CHECK: %pea.field.phi = phi i32 [ 2, %f ], [ 1, %t ]
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 200 to ptr), i32 16, i1 false)
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
; CHECK: store atomic i32 %pea.field.phi, ptr addrspace(1) %pea.matslot unordered, align 4
; CHECK: call void @sinkp(ptr addrspace(1) %gp)
; CHECK: %pea.matslot1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
; CHECK: store atomic i32 %pea.field.phi, ptr addrspace(1) %pea.matslot1 unordered, align 4
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK-NOT: poison

!java-method-compilation = !{}
