; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA Case C identity-bail — diamond CFG, both arms allocate the same Klass
; and write the same field, BUT the left arm's allocation is ALSO referenced
; by a second LLVM PHI in a different merge block. The "isSingleUsageAlloc"
; check in synthesizeCaseC sees the left alloc has more than one PHI user
; and bails (otherwise the second PHI could observe object identity through
; an identity comparison post-merge, observably equating two distinct
; runtime allocations). Falls through to Case A; both arms materialize.
;
; Structure:
;   entry -> (left|right) -> merge1 -> tail
;              left also -> merge2 with %o1 as one incoming
; merge2 forces %o1 to have a second PHI user.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_casec_identity_bail(i1 %c, i1 %d)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %left, label %right
left:
  %o1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %lcont unwind label %u
lcont:
  ; A second use of %o1 in an unrelated PHI (in alt-merge). This forces
  ; the identity check in Case C to bail.
  br i1 %d, label %alt_merge, label %merge1
right:
  %o2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %rcont unwind label %u
rcont:
  br label %merge1
merge1:
  %p1 = phi ptr addrspace(1) [ %o1, %lcont ], [ %o2, %rcont ]
  call void @sink(ptr addrspace(1) %p1)
  br label %tail
alt_merge:
  ; A separate PHI using %o1; observable identity bail.
  %p2 = phi ptr addrspace(1) [ %o1, %lcont ]
  call void @sink(ptr addrspace(1) %p2)
  br label %tail
tail:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Identity bail -> Case A -> both arms materialize.
; CHECK-LABEL: define void @test_casec_identity_bail
; CHECK: invoke hotspotcc {{.*}}@jeandle.new_instance
; CHECK: invoke hotspotcc {{.*}}@jeandle.new_instance

!java-method-compilation = !{}
