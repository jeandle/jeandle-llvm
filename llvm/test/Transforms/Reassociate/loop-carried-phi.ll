; RUN: opt < %s -passes=reassociate -S | FileCheck %s

; Tests for the OpCategory-driven leaf placement that handles loop-carried
; recurrence phis correctly. The recurrence target must sort to the OUTERMOST
; RHS of the rebuilt add chain so the loop carry is a single ALU operation;
; loop-invariants must sort to the INNERMOST RHS so LICM can hoist them; and
; loop-variant body computations occupy the middle, ordered by rank.

; ---------------------------------------------------------------------------
; Single-latch loop-carried recurrence
; ---------------------------------------------------------------------------
; A loop-carried header phi `%s` is the recurrence target of an add chain
; that also references two loop-body values (`%m = a*7` and `%r = a>>2`).
; Without OpCategory, Reassociate ranks `%s` at the loop header's RPO
; position (the lowest within the loop) and sinks it into the innermost LHS
; of the add chain, producing
;
;   ((%r + %s) + %m)         (2-cycle loop-carried dep on `%s`)
;
; instead of the natural construction order
;
;   ((%m + %r) + %s)         (1-cycle loop-carried dep on `%s`)
;
; OpCategory tags `%s` as LoopCarriedRecurrence so it sorts to Ops[0] and
; lands at the outer RHS where the recurrence latency is one ALU.

define i32 @loop_carried_phi_recurrence(i32 %n, ptr %arr) {
; CHECK-LABEL: @loop_carried_phi_recurrence
; CHECK:       loop:
; CHECK:         %s = phi i32 [ 0, %entry ], [ [[ADD2:%.*]], %loop ]
; CHECK:         [[M:%.*]] = mul i32 %v, 7
; CHECK:         [[R:%.*]] = lshr i32 %v, 2
; CHECK:         [[ADD1:%.*]] = add i32 [[M]], [[R]]
; CHECK:         [[ADD2]] = add i32 [[ADD1]], %s
; CHECK:         br i1
entry:
  br label %loop

loop:
  %s = phi i32 [ 0, %entry ], [ %add2, %loop ]
  %i = phi i32 [ 0, %entry ], [ %i.next, %loop ]
  %p = getelementptr i32, ptr %arr, i32 %i
  %v = load i32, ptr %p, align 4
  %m = mul i32 %v, 7
  %r = lshr i32 %v, 2
  %add1 = add i32 %m, %r
  %add2 = add i32 %add1, %s
  %i.next = add i32 %i, 1
  %cmp = icmp slt i32 %i.next, %n
  br i1 %cmp, label %loop, label %exit

exit:
  ret i32 %add2
}

; ---------------------------------------------------------------------------
; Multi-latch loop-carried recurrence
; ---------------------------------------------------------------------------
; Same recurrence as above but the loop has two latch edges (early-continue
; out of an if-then arm). `getLoopLatch()` returns nullptr for such loops;
; using it would silently skip the classification. OpClassifier uses
; `L->contains(IncomingBlock)` on every incoming, which is robust here.

define i32 @loop_carried_phi_multi_latch(i32 %n, ptr %arr) {
; CHECK-LABEL: @loop_carried_phi_multi_latch
; CHECK:       loop_header:
; CHECK:         %s = phi i32 [ 0, %entry ], [ [[NEXT:%.*]], %then ], [ [[NEXT]], %else ]
; CHECK:         [[M:%.*]] = mul i32 %v, 7
; CHECK:         [[R:%.*]] = lshr i32 %v, 2
; CHECK:         [[ADD1:%.*]] = add i32 [[M]], [[R]]
; CHECK:         [[NEXT]] = add i32 [[ADD1]], %s
entry:
  br label %loop_header

loop_header:
  %s = phi i32 [ 0, %entry ], [ %next, %then ], [ %next, %else ]
  %i = phi i32 [ 0, %entry ], [ %i.next, %then ], [ %i.next, %else ]
  %p = getelementptr i32, ptr %arr, i32 %i
  %v = load i32, ptr %p, align 4
  %m = mul i32 %v, 7
  %r = lshr i32 %v, 2
  %add1 = add i32 %m, %r
  %next = add i32 %add1, %s
  %i.next = add i32 %i, 1
  %odd = and i32 %i, 1
  %cmp.odd = icmp eq i32 %odd, 0
  br i1 %cmp.odd, label %then, label %else

then:
  %cmp.t = icmp slt i32 %i.next, %n
  br i1 %cmp.t, label %loop_header, label %exit

else:
  %cmp.e = icmp slt i32 %i.next, %n
  br i1 %cmp.e, label %loop_header, label %exit

exit:
  %r.merge = phi i32 [ %next, %then ], [ %next, %else ]
  ret i32 %r.merge
}

; ---------------------------------------------------------------------------
; Outer-loop recurrence: a phi from the OUTER loop's header that is used in
; the outer loop's body is itself a recurrence target. The fact that this
; loop has an inner sub-loop must NOT prevent the classification -- what
; matters is that the expression and the phi belong to the SAME loop.
;
; OpClassifier compares the phi's parent block to the *enclosing* loop's
; header (the loop containing the expression being reassociated), so an
; outer-loop expression's outer-loop phi is correctly tagged as
; LoopCarriedRecurrence.
; ---------------------------------------------------------------------------

define i32 @loop_carried_phi_outer_with_inner_sibling(i32 %n, ptr %arr) {
; CHECK-LABEL: @loop_carried_phi_outer_with_inner_sibling
; CHECK:       outer:
; CHECK:         %s = phi i32 [ 0, %entry ], [ [[ADD2:%.*]], %outer.latch ]
; CHECK:         [[M:%.*]] = mul i32 %v, 7
; CHECK:         [[R:%.*]] = lshr i32 %v, 2
; CHECK:         [[ADD1:%.*]] = add i32 [[M]], [[R]]
; CHECK:         [[ADD2]] = add i32 [[ADD1]], %s
entry:
  br label %outer

outer:
  %s = phi i32 [ 0, %entry ], [ %add2, %outer.latch ]
  %i = phi i32 [ 0, %entry ], [ %i.next, %outer.latch ]
  %p = getelementptr i32, ptr %arr, i32 %i
  %v = load i32, ptr %p, align 4
  %m = mul i32 %v, 7
  %r = lshr i32 %v, 2
  %add1 = add i32 %m, %r
  %add2 = add i32 %add1, %s
  br label %inner

inner:
  %j = phi i32 [ 0, %outer ], [ %j.next, %inner ]
  call void @use(i32 %j)
  %j.next = add i32 %j, 1
  %cmp.j = icmp slt i32 %j.next, %n
  br i1 %cmp.j, label %inner, label %outer.latch

outer.latch:
  %i.next = add i32 %i, 1
  %cmp.i = icmp slt i32 %i.next, %n
  br i1 %cmp.i, label %outer, label %exit

exit:
  ret i32 %add2
}

; ---------------------------------------------------------------------------
; Nested-loop "looptest.ll" preservation: in an inner-loop expression that
; references both inner-loop phis and outer-loop phis, only the inner-loop
; phi is the recurrence target. Outer-loop phis are loop-invariant relative
; to the inner loop and must stay at the innermost RHS so LICM can group
; and hoist them.
;
; Verify the inner-most expression `i + j + k` is reordered to put `k` (the
; innermost recurrence) at OUTER RHS and `(i + j)` (both outer invariants)
; at the innermost LHS subtree -- the canonical shape LICM expects.
; ---------------------------------------------------------------------------

define void @nested_loop_outer_phis_grouped_for_licm(i32 %n) {
; CHECK-LABEL: @nested_loop_outer_phis_grouped_for_licm
; CHECK:       inner.body:
; CHECK:         [[SUM:%.*]] = add i32 %j, %i
; CHECK-NEXT:    [[SUM2:%.*]] = add i32 [[SUM]], %k
entry:
  br label %outer

outer:
  %i = phi i32 [ 0, %entry ], [ %i.next, %outer.latch ]
  br label %middle

middle:
  %j = phi i32 [ 0, %outer ], [ %j.next, %middle.latch ]
  br label %inner

inner:
  br label %inner.body

inner.body:
  %k = phi i32 [ 0, %inner ], [ %k.next, %inner.body ]
  %sum = add i32 %i, %k
  %sum2 = add i32 %sum, %j
  call void @use(i32 %sum2)
  %k.next = add i32 %k, 1
  %cmp.k = icmp slt i32 %k.next, %n
  br i1 %cmp.k, label %inner.body, label %middle.latch

middle.latch:
  %j.next = add i32 %j, 1
  %cmp.j = icmp slt i32 %j.next, %n
  br i1 %cmp.j, label %middle, label %outer.latch

outer.latch:
  %i.next = add i32 %i, 1
  %cmp.i = icmp slt i32 %i.next, %n
  br i1 %cmp.i, label %outer, label %exit

exit:
  ret void
}

; ---------------------------------------------------------------------------
; Mixed-category sanity: one expression with the three categories of leaf in
; it (recurrence phi, loop-variant body computation, loop-invariant from
; outside). Each must end up in its category's expected position in the
; rebuilt tree:
;
;   Ops[0] = %s     (LoopCarriedRecurrence -> outermost RHS)
;   Ops[1] = %body  (LoopVariant            -> innermost LHS)
;   Ops[2] = %invar (LoopInvariantOrConst   -> innermost RHS)
;
; Inner subtree is `add %body, %invar` (within-category rank-desc tiebreaker
; picks the higher-ranked %body for LHS); outer is `add (that), %s`. This
; gives the standard 1-ALU loop carry on %s and groups %invar with the LICM
; candidates at the deepest position.
; ---------------------------------------------------------------------------

define i32 @mixed_category_leaves(i32 %n, ptr %arr, i32 %invar) {
; CHECK-LABEL: @mixed_category_leaves
; CHECK:       loop:
; CHECK:         %s = phi i32 [ 0, %entry ], [ [[NEXT:%.*]], %loop ]
; CHECK:         [[BODY:%.*]] = mul i32 %v, 13
; CHECK:         [[ACC1:%.*]] = add i32 [[BODY]], %invar
; CHECK:         [[NEXT]] = add i32 [[ACC1]], %s
entry:
  br label %loop

loop:
  %s = phi i32 [ 0, %entry ], [ %next, %loop ]
  %i = phi i32 [ 0, %entry ], [ %i.next, %loop ]
  %p = getelementptr i32, ptr %arr, i32 %i
  %v = load i32, ptr %p, align 4
  %body = mul i32 %v, 13
  %t1 = add i32 %s, %invar
  %next = add i32 %t1, %body
  %i.next = add i32 %i, 1
  %cmp = icmp slt i32 %i.next, %n
  br i1 %cmp, label %loop, label %exit

exit:
  ret i32 %next
}

; ---------------------------------------------------------------------------
; Floating-point recurrence with `fast` flags. The two body multiplications
; use DIFFERENT load bases (%v and %w) so Reassociate's common-factor pass
; cannot fuse them into a single `v * (7.0+0.25)` -- that would short-circuit
; the test to a 2-leaf path that goes through canonicalizeOperands (rank-
; only) instead of the 3-leaf rebuild (category + rank), defeating the
; intent of testing the category-driven placement on FP.
; ---------------------------------------------------------------------------

define float @fp_recurrence_fast(i32 %n, ptr %p, ptr %q) {
; CHECK-LABEL: @fp_recurrence_fast
; CHECK:       loop:
; CHECK:         %s = phi float [ 0.000000e+00, %entry ], [ [[ADD2:%.*]], %loop ]
; CHECK:         [[M:%.*]] = fmul fast float %v, 7.000000e+00
; CHECK:         [[R:%.*]] = fmul fast float %w, 2.500000e-01
; %r and %m are both LoopVariant; within-category tiebreak by rank desc puts
; %r first because %w (defined later than %v) bumps the BB-rank offset of %r
; above %m. Operands within the commutative fadd are interchangeable, so the
; choice has no effect on correctness or perf.
; CHECK:         [[ADD1:%.*]] = fadd fast float [[R]], [[M]]
; CHECK:         [[ADD2]] = fadd fast float [[ADD1]], %s
entry:
  br label %loop

loop:
  %s = phi float [ 0.0, %entry ], [ %add2, %loop ]
  %i = phi i32 [ 0, %entry ], [ %i.next, %loop ]
  %pp = getelementptr float, ptr %p, i32 %i
  %qp = getelementptr float, ptr %q, i32 %i
  %v = load float, ptr %pp, align 4
  %w = load float, ptr %qp, align 4
  %m = fmul fast float %v, 7.0
  %r = fmul fast float %w, 0.25
  %add1 = fadd fast float %m, %r
  %add2 = fadd fast float %add1, %s
  %i.next = add i32 %i, 1
  %cmp = icmp slt i32 %i.next, %n
  br i1 %cmp, label %loop, label %exit

exit:
  ret float %add2
}

; ---------------------------------------------------------------------------
; Self-loop: the simplest possible loop, a single BB that branches back to
; itself. The header IS the latch, in-loop incoming is the BB itself.
; OpClassifier must still recognise the loop-carried phi correctly when the
; loop has exactly one BB.
; ---------------------------------------------------------------------------

define i32 @self_loop_recurrence(i32 %n, ptr %arr) {
; CHECK-LABEL: @self_loop_recurrence
; CHECK:       loop:
; CHECK:         %s = phi i32 [ 0, %entry ], [ [[ADD2:%.*]], %loop ]
; CHECK:         [[M:%.*]] = mul i32 %v, 3
; CHECK:         [[R:%.*]] = lshr i32 %v, 1
; CHECK:         [[ADD1:%.*]] = add i32 [[M]], [[R]]
; CHECK:         [[ADD2]] = add i32 [[ADD1]], %s
entry:
  br label %loop

loop:
  %s = phi i32 [ 0, %entry ], [ %add2, %loop ]
  %i = phi i32 [ 0, %entry ], [ %i.next, %loop ]
  %p = getelementptr i32, ptr %arr, i32 %i
  %v = load i32, ptr %p, align 4
  %m = mul i32 %v, 3
  %r = lshr i32 %v, 1
  %add1 = add i32 %m, %r
  %add2 = add i32 %add1, %s
  %i.next = add i32 %i, 1
  %cmp = icmp slt i32 %i.next, %n
  br i1 %cmp, label %loop, label %exit

exit:
  ret i32 %add2
}

; ---------------------------------------------------------------------------
; Vector-typed recurrence: same shape as the scalar tests, but the phi and
; chain are `<4 x i32>`. OpClassifier is type-agnostic -- it works on SSA
; structure only -- so the same recurrence placement must occur.
; ---------------------------------------------------------------------------

define <4 x i32> @vector_recurrence(i32 %n, ptr %arr) {
; CHECK-LABEL: @vector_recurrence
; CHECK:       loop:
; CHECK:         %s = phi <4 x i32> [ zeroinitializer, %entry ], [ [[ADD2:%.*]], %loop ]
; CHECK:         [[M:%.*]] = mul <4 x i32> %v, splat (i32 7)
; CHECK:         [[R:%.*]] = lshr <4 x i32> %v, splat (i32 2)
; CHECK:         [[ADD1:%.*]] = add <4 x i32> [[M]], [[R]]
; CHECK:         [[ADD2]] = add <4 x i32> [[ADD1]], %s
entry:
  br label %loop

loop:
  %s = phi <4 x i32> [ zeroinitializer, %entry ], [ %add2, %loop ]
  %i = phi i32 [ 0, %entry ], [ %i.next, %loop ]
  %p = getelementptr <4 x i32>, ptr %arr, i32 %i
  %v = load <4 x i32>, ptr %p, align 16
  %m = mul <4 x i32> %v, <i32 7, i32 7, i32 7, i32 7>
  %r = lshr <4 x i32> %v, <i32 2, i32 2, i32 2, i32 2>
  %add1 = add <4 x i32> %m, %r
  %add2 = add <4 x i32> %add1, %s
  %i.next = add i32 %i, 1
  %cmp = icmp slt i32 %i.next, %n
  br i1 %cmp, label %loop, label %exit

exit:
  ret <4 x i32> %add2
}

; ---------------------------------------------------------------------------
; Single-BB function (no loops at all): OpClassifier returns LoopVariant
; for every non-constant leaf (because EnclosingLoop is null), making the
; category comparator a no-op tiebreaker. Ordering reduces to the legacy
; rank-only comparator exactly, so the resulting IR shape must be the same
; as before the OpCategory introduction. Locks down "single-BB recovers
; legacy behaviour."
;
; A 3-leaf add chain `a + b + c` (arguments) where a and c have higher
; rank than b: the legacy form is `(b + a) + c` or `(b + c) + a` depending
; on argument rank assignment. The key invariant we lock down is that
; this still produces a SINGLE add chain (no folding to constants, no
; perturbation introduced by the patch).
; ---------------------------------------------------------------------------

define i32 @single_bb_no_loops(i32 %a, i32 %b, i32 %c) {
; CHECK-LABEL: @single_bb_no_loops
; Argument ranks (legacy BuildRankMap): %a=3, %b=4, %c=5 (assigned in order).
; Descending sort gives Ops = [%c, %b, %a]; rebuild puts Ops[0]=%c at the
; outermost RHS and (Ops[1], Ops[2]) = (%b, %a) as the inner add. Lock
; down this exact ordering -- any deviation would mean the OpClassifier
; (which here returns LoopVariant for every leaf because EnclosingLoop is
; null) is no longer a no-op tiebreaker, indicating a regression in the
; "single-BB recovers legacy" invariant.
; CHECK-NEXT:    [[ADD1:%.*]] = add i32 %b, %a
; CHECK-NEXT:    [[ADD2:%.*]] = add i32 [[ADD1]], %c
; CHECK-NEXT:    ret i32 [[ADD2]]
  %t = add i32 %a, %b
  %r = add i32 %t, %c
  ret i32 %r
}

; ---------------------------------------------------------------------------
; XOR recurrence: Reassociate handles xor like add (associative). The
; OpClassifier doesn't differentiate by opcode, so the same recurrence
; placement that applies to add chains must apply to xor chains. Verify by
; constructing `s ^= v*7 ^ (v>>>2)` and asserting %s lands at the outer RHS
; of the xor chain.
; ---------------------------------------------------------------------------

define i32 @loop_carried_xor_recurrence(i32 %n, ptr %arr) {
; CHECK-LABEL: @loop_carried_xor_recurrence
; CHECK:       loop:
; CHECK:         %s = phi i32 [ 0, %entry ], [ [[X2:%.*]], %loop ]
; CHECK:         [[M:%.*]] = mul i32 %v, 7
; CHECK:         [[R:%.*]] = lshr i32 %v, 2
; CHECK:         [[X1:%.*]] = xor i32 [[M]], [[R]]
; CHECK:         [[X2]] = xor i32 [[X1]], %s
entry:
  br label %loop

loop:
  %s = phi i32 [ 0, %entry ], [ %x2, %loop ]
  %i = phi i32 [ 0, %entry ], [ %i.next, %loop ]
  %p = getelementptr i32, ptr %arr, i32 %i
  %v = load i32, ptr %p, align 4
  %m = mul i32 %v, 7
  %r = lshr i32 %v, 2
  %x1 = xor i32 %m, %r
  %x2 = xor i32 %x1, %s
  %i.next = add i32 %i, 1
  %cmp = icmp slt i32 %i.next, %n
  br i1 %cmp, label %loop, label %exit

exit:
  ret i32 %x2
}

; ---------------------------------------------------------------------------
; MUL recurrence: the third op family Reassociate cares about. Same shape
; assertion as the integer and xor cases.
; ---------------------------------------------------------------------------

define i32 @loop_carried_mul_recurrence(i32 %n, ptr %p, ptr %q) {
; CHECK-LABEL: @loop_carried_mul_recurrence
; CHECK:       loop:
; CHECK:         %p_acc = phi i32 [ 1, %entry ], [ [[OUT:%.*]], %loop ]
; Reassociate's common-factor pass fuses the two constants 3 and 5 into a
; single 15, producing a chain of three leaves [%v*15, %w, %p_acc]. The
; key property under test is that the loop-carried %p_acc still lands at
; the OUTERMOST RHS of the rebuilt chain, regardless of which constants
; got absorbed into which leaf along the way.
; CHECK:         [[A:%.*]] = mul i32 %v, 15
; CHECK:         [[INNER:%.*]] = mul i32 [[A]], %w
; CHECK:         [[OUT]] = mul i32 [[INNER]], %p_acc
entry:
  br label %loop

loop:
  %p_acc = phi i32 [ 1, %entry ], [ %out, %loop ]
  %i = phi i32 [ 0, %entry ], [ %i.next, %loop ]
  %pp = getelementptr i32, ptr %p, i32 %i
  %qp = getelementptr i32, ptr %q, i32 %i
  %v = load i32, ptr %pp, align 4
  %w = load i32, ptr %qp, align 4
  %a = mul i32 %v, 3
  %b = mul i32 %w, 5
  %inner = mul i32 %a, %b
  %out = mul i32 %inner, %p_acc
  %i.next = add i32 %i, 1
  %cmp = icmp slt i32 %i.next, %n
  br i1 %cmp, label %loop, label %exit

exit:
  ret i32 %out
}

; ---------------------------------------------------------------------------
; Jeandle-style IR shape: the recurrence has a statepoint-like opaque call
; in the loop body. This is precisely the IR pattern that motivated the
; deep refactor -- Jeandle's safepoint polls (which become statepoints
; after RewriteStatepointsForGC) live inside the loop body and prevent
; LoopVectorize from firing. We need to confirm Reassociate's recurrence
; placement is unaffected by the opaque call's presence.
; ---------------------------------------------------------------------------

; Declared with no attributes: the call is assumed to have unknown memory
; effects, so DCE / CSE cannot remove it even when its return value is
; unused. This is exactly the property a Jeandle safepoint / statepoint
; has -- opaque to the optimizer but not blocking adjacent computation.
declare void @opaque_call()

define i32 @recurrence_with_opaque_call_in_body(i32 %n, ptr %arr) {
; CHECK-LABEL: @recurrence_with_opaque_call_in_body
; CHECK:       loop:
; CHECK:         %s = phi i32 [ 0, %entry ], [ [[ADD2:%.*]], %loop ]
; CHECK:         call void @opaque_call()
; CHECK:         [[M:%.*]] = mul i32 %v, 7
; CHECK:         [[R:%.*]] = lshr i32 %v, 2
; CHECK:         [[ADD1:%.*]] = add i32 [[M]], [[R]]
; CHECK:         [[ADD2]] = add i32 [[ADD1]], %s
entry:
  br label %loop

loop:
  %s = phi i32 [ 0, %entry ], [ %add2, %loop ]
  %i = phi i32 [ 0, %entry ], [ %i.next, %loop ]
  %p = getelementptr i32, ptr %arr, i32 %i
  %v = load i32, ptr %p, align 4
  call void @opaque_call()                       ; safepoint-like opaque call
  %m = mul i32 %v, 7
  %r = lshr i32 %v, 2
  %add1 = add i32 %m, %r
  %add2 = add i32 %add1, %s
  %i.next = add i32 %i, 1
  %cmp = icmp slt i32 %i.next, %n
  br i1 %cmp, label %loop, label %exit

exit:
  ret i32 %add2
}

; ---------------------------------------------------------------------------
; Triple-nested loops: the outermost recurrence `%S_OUT` must still be
; recognised as such even when there are TWO levels of inner sub-loops.
; The legacy innermost-only restriction would have left outer-loop
; recurrences mishandled at any nesting depth; dropping it must generalise
; cleanly. Also verify the innermost loop's own recurrence `%s_in` is
; correctly placed too.
; ---------------------------------------------------------------------------

define i32 @triple_nested_recurrences(i32 %n, ptr %arr) {
; CHECK-LABEL: @triple_nested_recurrences
; CHECKs follow the IR block order (RPO): inner first, then outer.latch.
; In the innermost loop body the inner recurrence %s_in must be at the
; outer RHS of its add chain:
; CHECK:       inner:
; CHECK:         %s_in = phi i32 [ 0, %middle ], [ [[INNER_ADD2:%.*]], %inner ]
; CHECK:         [[INNER_M:%.*]] = mul i32 %v, 7
; CHECK:         [[INNER_R:%.*]] = lshr i32 %v, 2
; CHECK:         [[INNER_ADD1:%.*]] = add i32 [[INNER_M]], [[INNER_R]]
; CHECK:         [[INNER_ADD2]] = add i32 [[INNER_ADD1]], %s_in
; In the outermost loop body the outer recurrence %s_out must also be at
; the outer RHS of its 3-leaf add chain (1-ALU loop carry on the outer
; loop). A 3-leaf chain is required to actually exercise OpCategory sort
; (2-leaf chains only go through canonicalizeOperands, rank-only):
; CHECK:       outer.latch:
; CHECK:         [[OUT_M:%.*]] = mul i32 %s_in, 11
; CHECK:         [[OUT_R:%.*]] = lshr i32 %s_in, 3
; CHECK:         [[OUT_BODY:%.*]] = add i32 [[OUT_M]], [[OUT_R]]
; CHECK:         [[OUT_NEXT:%.*]] = add i32 [[OUT_BODY]], %s_out
entry:
  br label %outer

outer:
  %s_out = phi i32 [ 0, %entry ], [ %out_next, %outer.latch ]
  %i = phi i32 [ 0, %entry ], [ %i.next, %outer.latch ]
  br label %middle

middle:
  %j = phi i32 [ 0, %outer ], [ %j.next, %middle.latch ]
  br label %inner

inner:
  %s_in = phi i32 [ 0, %middle ], [ %inner_add2, %inner ]
  %k = phi i32 [ 0, %middle ], [ %k.next, %inner ]
  %p = getelementptr i32, ptr %arr, i32 %k
  %v = load i32, ptr %p, align 4
  %inner_m = mul i32 %v, 7
  %inner_r = lshr i32 %v, 2
  %inner_add1 = add i32 %inner_m, %inner_r
  %inner_add2 = add i32 %inner_add1, %s_in
  %k.next = add i32 %k, 1
  %cmp.k = icmp slt i32 %k.next, %n
  br i1 %cmp.k, label %inner, label %middle.latch

middle.latch:
  %j.next = add i32 %j, 1
  %cmp.j = icmp slt i32 %j.next, %n
  br i1 %cmp.j, label %middle, label %outer.latch

outer.latch:
  ; Outer recurrence add chain: %s_out is the loop-carried accumulator;
  ; %out_m and %out_r are body-derived from the inner-loop result %s_in.
  ; Three leaves [%s_out, %out_m, %out_r] -> goes through OpCategory sort,
  ; verifying that %s_out lands at the outermost RHS even when this loop
  ; has inner sub-loops (i.e. is NOT itself innermost).
  %out_m = mul i32 %s_in, 11
  %out_r = lshr i32 %s_in, 3
  %out_body = add i32 %out_m, %out_r
  %out_next = add i32 %out_body, %s_out
  %i.next = add i32 %i, 1
  %cmp.i = icmp slt i32 %i.next, %n
  br i1 %cmp.i, label %outer, label %exit

exit:
  ret i32 %out_next
}

declare void @use(i32)
