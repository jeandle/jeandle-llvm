; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Loop-convergence regression: the single-state loop-convergence test
; (Analyzer::exitDataEquivalent) must treat two states as NON-equivalent
; whenever an ObjectID is present in one and absent in the other. Every map
; (Virtuals, Materialized, FieldStates, LockCounts, LiveLockEnters,
; MaterializedValues) is size-checked before key iteration, so a present-vs-
; absent difference returns false (no debug/release divergence).
;
; Shape: %a is allocated BEFORE the loop (virtual on loop entry → present in the
; Virtuals set of B := A) and escapes UNCONDITIONALLY inside the body (→ moves
; to the Materialized set, absent from Virtuals, in B'). If the convergence
; check wrongly treated "virtual present" and "virtual absent" as equivalent it
; would falsely converge and drop the required materialization — a miscompile.
; The sound result keeps the allocation live and the escape store intact.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

@G = external addrspace(1) global ptr addrspace(1)

define void @test_present_absent(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 4242 to ptr), i32 16, i1 false)
       to label %preheader unwind label %u
preheader:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 1, ptr addrspace(1) %slot unordered, align 4
  br label %hdr

hdr:
  %i = phi i32 [0, %preheader], [%inext, %latch]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit

body:
  ; Unconditional escape of the before-loop object every iteration: this is the
  ; state transition (virtual -> materialized) that B-vs-B' must see as a real
  ; difference rather than collapsing it.
  store ptr addrspace(1) %a, ptr addrspace(1) @G
  br label %latch
latch:
  %inext = add i32 %i, 1
  br label %hdr

exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Sound output: the allocation survives (materialized) and the escaping store is
; preserved; the function compiles cleanly (verifier clean).
; CHECK-LABEL: define void @test_present_absent
; CHECK: invoke {{.*}}@jeandle.new_instance({{.*}}i64 4242
; CHECK: store ptr addrspace(1)

!java-method-compilation = !{}
