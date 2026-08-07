; RUN: not --crash opt -passes='verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -disable-output < %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=ABORT

; The coverage verifier must NOT treat an alloc fast path as
; loop coverage: a TLAB bump carries a "deopt" bundle for deoptimization STATE
; but never polls, so a poll-less loop dominated only by such a call is
; uncovered and must be reported. isSafepoint() excludes calls marked
; NotGuaranteedSafepoint, so the verifier reports the violation (fatal aborts).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32) #0

attributes #0 = { "jeandle.not-guaranteed-safepoint" }

define void @alloc_only_loop_uncovered(ptr %flag) "java-method" {
entry:
  br label %header

header:
  %done = load i1, ptr %flag, align 1
  br i1 %done, label %exit, label %latch

latch:
  %o = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr null, i32 16) [ "deopt"() ]
  br label %header

exit:
  ret void
}

!java-method-compilation = !{}

; ABORT: SafepointCoverageVerifier: loop with header 'header' in function 'alloc_only_loop_uncovered' has an uncovered backedge path and no provable trip bound
; ABORT: Jeandle safepoint coverage verification failed
