; RUN: opt -S -passes="loop-simplify,partial-escape-iterative,instcombine,simplifycfg,adce" -jeandle-pea-iterations=2 %s | FileCheck %s

; End-to-end pipeline composition. Wires up the same passes the
; production pipeline runs around PEA — LoopSimplify (preheader / LCSSA
; canonicalization) -> partial-escape-iterative (inner loop fixpoint +
; outer iteration) -> InstCombine + SimplifyCFG + ADCE (canonicalisation
; tail). Verifies that running PEA inside this composition still produces
; the expected end state on a synthetic loop-virtualisable case.
;
; The function allocates an instance, threads it through a counted loop
; that stores and loads a single field on every iteration, and finally
; returns the field value. With PEA's loop fixpoint, the alloc never
; escapes; the per-iteration store/load fold against tracked field
; state and the alloc is eliminated entirely. After canonicalisation
; the function reduces to a constant return.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @test_loop_field_fold()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %loop unwind label %u
loop:
  %i = phi i32 [ 0, %entry ], [ %i.next, %loop ]
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 99, ptr addrspace(1) %slot unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  %i.next = add i32 %i, 1
  %done = icmp eq i32 %i.next, 4
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The full composition virtualizes %o, folds the per-iteration store/load
; into a single tracked-field constant, and the canonicalisation tail
; reduces the function to a constant return.
; CHECK-LABEL: define i32 @test_loop_field_fold
; CHECK-NOT: jeandle.new_instance
; CHECK: ret i32 99

!java-method-compilation = !{}
