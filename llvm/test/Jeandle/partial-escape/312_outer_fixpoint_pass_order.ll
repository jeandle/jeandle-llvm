; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=4 %s | FileCheck %s

; The outer-fixpoint canonicalisation passes run in the order
; ADCE → SimplifyCFG → LoopSimplify → InstCombine. Putting DCE first
; means InstCombine never folds against now-dead IR that PEA's prior
; round emitted as materialisation scaffolding.
;
; This pattern: round 0 materialises %o on the escape arm; ADCE in round
; 0 prunes the post-materialise dead invoke (after the SimplifyCFG pass
; eliminates the always-false branch), then InstCombine canonicalises
; the surviving control flow. Round 1's analysis sees a single straight-
; line shape and virtualises %o end-to-end.
;
; If InstCombine ran FIRST, it would observe the still-live materialised
; invoke and could fold a select that depends on the dying allocation
; pointer — wasting work on IR that ADCE will reap one step later.

@G_zero = private unnamed_addr constant i32 0

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i32 @test_pass_order()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 44444 to ptr), i32 16, i1 false)
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
  store atomic i32 99, ptr addrspace(1) %slot unordered, align 4
  %val = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  ret i32 %val
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; All allocs/escapes/load eliminated. Function reduces to ret i32 99.
; CHECK-LABEL: define i32 @test_pass_order()
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: call void @sink
; CHECK: ret i32 99

!java-method-compilation = !{}
