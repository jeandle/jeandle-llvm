; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -verify-each %s | FileCheck %s

; Regression for a dangling-Value* in restoreLoopSnapshot's rollback cleanup.
;
; restoreLoopSnapshot preserves BlockExits[BB] for every loop block so the
; next iteration's in-pass mergeStates(Header) can read each back-edge
; pred's exit state via exitDataFor, and its cleanup deletes unparented PHIs
; created during the rolled-back iteration from Result.OwnedPhis. A
; NON-HEADER in-loop merge block (here: "latch") must not have its
; synthesized field PHI owned by OwnedPhis (via createUnparentedPhi): the
; PHI would be deleted on rollback while
; BlockExits[latch].FieldStates[%o][12] still references it, leaving a
; dangling Value* for the next iteration's mergeStates(Header) ->
; exitDataFor.
;
; getOrCreateLoopFieldPhi therefore gates on LI.getLoopFor(BB) != nullptr
; (not just LoopHeaderSet), so every in-loop merge-block PHI is cached per
; (BB, ID, Off) in OwnedLoopFieldPhis (which restoreLoopSnapshot does NOT
; pop) and stays stable across iterations.
;
; Each variant forces loop-carried state so iter 0 does not converge and the
; iter 1 rollback fires. A debug assert in restoreLoopSnapshot makes the UAF
; deterministic on every variant that builds a non-header in-loop merge PHI.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare void @usep(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

; -----------------------------------------------------------------------------
; Variant A: scalar i32 field, then/else merge at a non-header "latch".
;             Exercises the mergeStates scalar field-PHI path.
; -----------------------------------------------------------------------------
define void @test_scalar_field_merge(i32 %n, i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 24, i1 false)
       to label %prep unwind label %u
prep:
  %fp0 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  store atomic i32 0, ptr addrspace(1) %fp0 unordered, align 4
  br label %hdr
hdr:
  %i = phi i32 [ 0, %prep ], [ %i1, %latch ]
  %cc = icmp slt i32 %i, %n
  br i1 %cc, label %body, label %exit
body:
  br i1 %c, label %then, label %else
then:
  %fp1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  store atomic i32 1, ptr addrspace(1) %fp1 unordered, align 4
  br label %latch
else:
  %fp2 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  store atomic i32 2, ptr addrspace(1) %fp2 unordered, align 4
  br label %latch
latch:
  %fpl = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  %fv = load atomic i32, ptr addrspace(1) %fpl unordered, align 4
  call void @use(i32 %fv)
  %i1 = add i32 %i, 1
  br label %hdr
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
; CHECK-LABEL: define void @test_scalar_field_merge
; CHECK-NOT: jeandle.new_instance
; The non-header latch merge synthesizes a pea.field.phi over [1, %then],
; [2, %else]; the latch load folds to it and feeds @use.
; CHECK: pea.field.phi[[A:[0-9]*]] = phi i32
; CHECK: call void @use(i32 %pea.field.phi[[A]])
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic

; -----------------------------------------------------------------------------
; Variant B: pointer-typed field, then/else merge at a non-header "latch".
;             Exercises FieldValue::materializedRef(Phi) (the
;             PhiType->isPointerTy() branch). Each arm stores a distinct
;             scalar pointer (null vs a constant ptr); the merge builds a
;             ptr addrspace(1) field PHI.
; -----------------------------------------------------------------------------
define void @test_pointer_field_merge(i32 %n, i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 33333 to ptr), i32 32, i1 false)
       to label %prep unwind label %u
prep:
  %gp0 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic ptr addrspace(1) null, ptr addrspace(1) %gp0 unordered, align 8
  br label %hdr
hdr:
  %i = phi i32 [ 0, %prep ], [ %i1, %latch ]
  %cc = icmp slt i32 %i, %n
  br i1 %cc, label %body, label %exit
body:
  br i1 %c, label %then, label %else
then:
  %gp1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic ptr addrspace(1) null, ptr addrspace(1) %gp1 unordered, align 8
  br label %latch
else:
  %gp2 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic ptr addrspace(1) inttoptr (i64 8888 to ptr addrspace(1)),
      ptr addrspace(1) %gp2 unordered, align 8
  br label %latch
latch:
  %gpl = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %pv = load atomic ptr addrspace(1), ptr addrspace(1) %gpl unordered, align 8
  call void @usep(ptr addrspace(1) %pv)
  %i1 = add i32 %i, 1
  br label %hdr
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
; CHECK-LABEL: define void @test_pointer_field_merge
; CHECK-NOT: jeandle.new_instance
; CHECK: pea.field.phi[[B:[0-9]*]] = phi ptr addrspace(1)
; CHECK: call void @usep(ptr addrspace(1) %pea.field.phi[[B]])
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic

; -----------------------------------------------------------------------------
; Variant C: multiple scalar fields (offsets 8, 12, 16) in the same arms.
;             Three independent latch field PHIs — exercises the (BB, ID, Off)
;             cache with multiple keys at one non-header in-loop merge.
; -----------------------------------------------------------------------------
define void @test_multi_field_merge(i32 %n, i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 44444 to ptr), i32 32, i1 false)
       to label %prep unwind label %u
prep:
  %p8a = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %p8b = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  %p8c = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 0, ptr addrspace(1) %p8a unordered, align 4
  store atomic i32 0, ptr addrspace(1) %p8b unordered, align 4
  store atomic i32 0, ptr addrspace(1) %p8c unordered, align 4
  br label %hdr
hdr:
  %i = phi i32 [ 0, %prep ], [ %i1, %latch ]
  %cc = icmp slt i32 %i, %n
  br i1 %cc, label %body, label %exit
body:
  br i1 %c, label %then, label %else
then:
  %t8 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %t12 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  %t16 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 1, ptr addrspace(1) %t8 unordered, align 4
  store atomic i32 3, ptr addrspace(1) %t12 unordered, align 4
  store atomic i32 5, ptr addrspace(1) %t16 unordered, align 4
  br label %latch
else:
  %e8 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %e12 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  %e16 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 2, ptr addrspace(1) %e8 unordered, align 4
  store atomic i32 4, ptr addrspace(1) %e12 unordered, align 4
  store atomic i32 6, ptr addrspace(1) %e16 unordered, align 4
  br label %latch
latch:
  %l8 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %l12 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  %l16 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %v8 = load atomic i32, ptr addrspace(1) %l8 unordered, align 4
  %v12 = load atomic i32, ptr addrspace(1) %l12 unordered, align 4
  %v16 = load atomic i32, ptr addrspace(1) %l16 unordered, align 4
  call void @use(i32 %v8)
  call void @use(i32 %v12)
  call void @use(i32 %v16)
  %i1 = add i32 %i, 1
  br label %hdr
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
; CHECK-LABEL: define void @test_multi_field_merge
; CHECK-NOT: jeandle.new_instance
; CHECK: pea.field.phi{{[0-9]*}} = phi i32
; CHECK: pea.field.phi{{[0-9]*}} = phi i32
; CHECK: pea.field.phi{{[0-9]*}} = phi i32
; CHECK: call void @use
; CHECK: call void @use
; CHECK: call void @use
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic

; -----------------------------------------------------------------------------
; Variant D: nested loop — a non-header merge block lives inside the INNER
;             loop. LI.getLoopFor(inner_latch) must return the inner loop so
;             the field PHI is cached and survives the inner fixpoint's
;             rollback. Exercises the innermost-loop behaviour of the
;             in-loop gate.
; -----------------------------------------------------------------------------
define void @test_nested_loop_inner_merge(i32 %n, i32 %m, i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 55555 to ptr), i32 24, i1 false)
       to label %oprep unwind label %u
oprep:
  %ofp0 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  store atomic i32 0, ptr addrspace(1) %ofp0 unordered, align 4
  br label %ohdr
ohdr:
  %oi = phi i32 [ 0, %oprep ], [ %oi1, %olatch ]
  %occ = icmp slt i32 %oi, %n
  br i1 %occ, label %obody, label %oexit
obody:
  br label %ihdr
ihdr:
  %ii = phi i32 [ 0, %obody ], [ %ii1, %ilatch ]
  %icc = icmp slt i32 %ii, %m
  br i1 %icc, label %ibody, label %iexit
ibody:
  br i1 %c, label %ithen, label %ielse
ithen:
  %ifp1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  store atomic i32 1, ptr addrspace(1) %ifp1 unordered, align 4
  br label %ilatch
ielse:
  %ifp2 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  store atomic i32 2, ptr addrspace(1) %ifp2 unordered, align 4
  br label %ilatch
ilatch:
  %ifpl = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  %ifv = load atomic i32, ptr addrspace(1) %ifpl unordered, align 4
  call void @use(i32 %ifv)
  %ii1 = add i32 %ii, 1
  br label %ihdr
iexit:
  br label %olatch
olatch:
  %oi1 = add i32 %oi, 1
  br label %ohdr
oexit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
; CHECK-LABEL: define void @test_nested_loop_inner_merge
; CHECK-NOT: jeandle.new_instance
; The inner non-header latch (ilatch) synthesizes a pea.field.phi over
; [1, %ithen], [2, %ielse] — the innermost-loop gate (LI.getLoopFor) keeps
; it cached across the inner fixpoint's rollback.
; CHECK: pea.field.phi{{[0-9]*}} = phi i32 [ {{[0-9]+}}, %ielse ], [ {{[0-9]+}}, %ithen ]
; CHECK: call void @use
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic

; -----------------------------------------------------------------------------
; Variant F (negative): straight-line loop body with NO non-header merge.
;             The only field PHI is the loop-carried header PHI (already
;             cached by the existing loop-header path). Confirms the in-loop
;             gate does not over-fire / break non-merge in-loop blocks, and
;             that a loop with no non-header merge PHI still eliminates
;             cleanly.
; -----------------------------------------------------------------------------
define void @test_no_merge_straight_body(i32 %n)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 66666 to ptr), i32 24, i1 false)
       to label %prep unwind label %u
prep:
  %fp0 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  store atomic i32 0, ptr addrspace(1) %fp0 unordered, align 4
  br label %hdr
hdr:
  %i = phi i32 [ 0, %prep ], [ %i1, %body ]
  %cc = icmp slt i32 %i, %n
  br i1 %cc, label %body, label %exit
body:
  %fpb = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  store atomic i32 7, ptr addrspace(1) %fpb unordered, align 4
  %fv = load atomic i32, ptr addrspace(1) %fpb unordered, align 4
  call void @use(i32 %fv)
  %i1 = add i32 %i, 1
  br label %hdr
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
; CHECK-LABEL: define void @test_no_merge_straight_body
; CHECK-NOT: jeandle.new_instance
; No non-header merge → no pea.field.phi; the body's loop-invariant store
; of 7 lets the load fold to the constant. Object eliminated; @use kept.
; CHECK: call void @use(i32 7)
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic

!java-method-compilation = !{}
