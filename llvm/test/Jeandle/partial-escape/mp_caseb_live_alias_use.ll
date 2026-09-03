; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; MergeProcessor / processBlockPhis Case B with a LIVE downstream use.
;
; Both arms of the diamond branch on the SAME virtual object %o, so the
; pointer PHI at the merge is a Case-B PHI (both incomings resolve to the
; same ObjectID). Unlike 321_m7_caseB_phi_eliminated (where the PHI has no
; pointer use), here the PHI feeds a real getelementptr + load downstream.
; The Case-B alias routes %phi -> %o's VO; propagatePointerAlias forwards
; the alias onto the GEP; the post-merge load folds to the stored constant
; and the PHI itself is erased (the VO is NeverEscapes).
;
; This pins the Case-B alias-routing path across MergeProcessor retries:
; when the per-phi Aliases.resetAlias runs at the top
; of each fixpoint iteration, the alias is re-derived identically and the
; downstream load still folds.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @test_caseb_live_use(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %s0 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 42, ptr addrspace(1) %s0 unordered, align 4
  br i1 %c, label %left, label %right
left:
  br label %merge
right:
  br label %merge
merge:
  %phi = phi ptr addrspace(1) [ %o, %left ], [ %o, %right ]
  %s = getelementptr inbounds i8, ptr addrspace(1) %phi, i64 8
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The alloc is eliminated, the Case-B PHI is erased, and the load folds to 42.
; CHECK-LABEL: define i32 @test_caseb_live_use
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: phi ptr addrspace(1)
; CHECK: ret i32 42

!java-method-compilation = !{}
