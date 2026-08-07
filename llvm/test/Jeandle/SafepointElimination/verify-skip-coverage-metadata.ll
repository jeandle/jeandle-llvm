; RUN: opt -passes='verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -disable-output < %s
; RUN: opt -passes='verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=warn -disable-output < %s 2>&1 | count 0

; The skip-safepoint-coverage-verifier named metadata opts a module out of the
; coverage verifier. It is set for compilation paths with different safepoint
; semantics (e.g. intrinsic lowering / runtime stubs on the HotSpot side), not
; for every Java method. The module below is otherwise a coverage violation — a
; naked loop with no poll and no induction variable — that verify-coverage-
; violation.ll shows the verifier rejects in both warn and fatal modes. With the
; opt-out metadata present, the verifier must skip it: fatal mode stays alive
; (first RUN exits 0) and warn mode is silent (second RUN emits nothing).

declare hotspotcc void @jeandle.safepoint_poll()

define void @naked_loop(ptr %p) "java-method" gc "safepoint-in-loop-example" {
entry:
  br label %loop.header

loop.header:
  %v = load i32, ptr %p
  %exit.cond = icmp eq i32 %v, 0
  br i1 %exit.cond, label %loop.header, label %exit

exit:
  ret void
}

!java-method-compilation = !{}
!skip-safepoint-coverage-verifier = !{}
