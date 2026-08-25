; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=4 %s | FileCheck %s

; Canonicalization progress in the outer fixpoint break condition.
;
; Round 0's PEA retains %o's OrigAlloc and plans replay on the escape arm.
; Round 0's
; canonicalisation (ADCE → SCFG → LoopSimplify → InstCombine) prunes the
; dead branch and consolidates the survivor blocks — this is the
; current-round canonicalization event: canonicalisation moved IR around, and
; the subsequent fresh analysis may discover new opportunities even if the
; next transform is idle.
;
; Convergence requires both an idle transform and unchanged exact printed IR
; from the same round's complete canonicalization sequence.

@G_zero = private unnamed_addr constant i32 0

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i32 @test_post_triggered()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 55555 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %v = load i32, ptr @G_zero, align 4
  %c = icmp ne i32 %v, 0
  br i1 %c, label %escape, label %fast
escape:
  call void @sink(ptr addrspace(1) %o)
  br label %fast
fast:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 11, ptr addrspace(1) %slot unordered, align 4
  %val = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  ret i32 %val
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_post_triggered()
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: call void @sink
; CHECK: ret i32 11

!java-method-compilation = !{}
