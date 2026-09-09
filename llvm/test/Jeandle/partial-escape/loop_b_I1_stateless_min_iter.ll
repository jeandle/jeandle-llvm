; REQUIRES: asserts
; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s --check-prefix=IR
; RUN: opt -disable-output -passes="require<partial-escape-analysis>" -stats %s 2>&1 | FileCheck %s --check-prefix=STATS

; A loop with only a loop-LOCAL allocation (created and consumed in the body
; every iteration; nothing carried across the back-edge). The header merged
; state B has no carried virtuals, so the fixpoint converges as fast as
; possible. With the Phase 2 post-body merge, iteration 0 already produces a
; true B' = A and the loop converges in a SINGLE body pass (matching the
; processLoop structure).
;
; The IR check pins the loop-local elimination; the STATS check pins the
; 1-iteration convergence.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_stateless_min_iter(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %i1, %st ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  %p = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 40801 to ptr), i32 16, i1 false)
       to label %st unwind label %u
st:
  %t = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  store atomic i32 5, ptr addrspace(1) %t unordered, align 4
  %w = load atomic i32, ptr addrspace(1) %t unordered, align 4
  call void @use(i32 %w)
  %i1 = add i32 %i, 1
  br label %loop
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Loop-local alloc eliminated; load folds to 5.
; IR-LABEL: define void @test_stateless_min_iter
; IR-NOT: jeandle.new_instance
; IR-NOT: store atomic
; IR-NOT: load atomic
; IR: call void @use(i32 5)

; Phase 2 (post-body merge): a single inner-fixpoint iteration (iteration 0
; produces B' = A via the post-body merge and converges immediately).
; STATS: 1 partial-escape-analysis - Sum of inner-fixpoint iterations across every processLoop call

!java-method-compilation = !{}
