; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; MergeProcessor / mergeFieldStates field-PHI at a TRUE self-loop header.
;
; The loop header `loop` is its own back-edge predecessor (br back to
; itself). The VO %o is allocated before the loop and stays virtual. A field
; (offset 8) is loop-carried: the preheader stores 1 (forward edge), the
; loop body stores the induction %i (back edge). At the header merge the
; per-offset field states disagree (1 vs %i), so mergeFieldStates synthesizes
; a per-offset i32 field PHI. Because the header is a loop header, the PHI
; shell must be STABLE across the loop-fixpoint iterations (LoopFieldPhiCache)
; or the convergence check would diverge.
;
; 120_loop_fixpoint_alloc_before_loop_field_mut is the two-block (header +
; body) version of this; this test carries the virtual field across a
; self back-edge, exercising field-PHI synthesis + cache stability when the
; merge block is its own predecessor.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_selfloop_field_phi(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %prep unwind label %u
prep:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 1, ptr addrspace(1) %s unordered, align 4
  br label %loop
loop:
  %i = phi i32 [ 0, %prep ], [ %i1, %loop ]
  store atomic i32 %i, ptr addrspace(1) %s unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  call void @use(i32 %v)
  %i1 = add i32 %i, 1
  %c = icmp slt i32 %i, %n
  br i1 %c, label %loop, label %exit
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Alloc + preheader store + loop-body store/load all eliminated. The body's
; @use receives %i (the load collapses to the just-stored value through the
; virtual field, same as the two-block 120 case).
; CHECK-LABEL: define void @test_selfloop_field_phi
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: call void @use(i32 %i)

!java-method-compilation = !{}
