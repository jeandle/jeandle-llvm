; RUN: opt -passes='safepoint-poll-elimination<early>' \
; RUN:   -jeandle-loop-strip-mining-iter=0 -S < %s | FileCheck %s --check-prefix=ELIM
; RUN: llvm-extract -func=uncovered_callsite_leaf_loop -S < %s \
; RUN:   | not --crash opt -passes='verify<jeandle-safepoint-coverage>' \
; RUN:     -jeandle-verify-safepoint-coverage=fatal -disable-output 2>&1 \
; RUN:   | FileCheck %s --check-prefix=CALLSITE-ABORT
; RUN: llvm-extract -func=uncovered_callee_leaf_loop -S < %s \
; RUN:   | not --crash opt -passes='verify<jeandle-safepoint-coverage>' \
; RUN:     -jeandle-verify-safepoint-coverage=fatal -disable-output 2>&1 \
; RUN:   | FileCheck %s --check-prefix=CALLEE-ABORT

; A GC-leaf call cannot reach a safepoint even when it carries a deopt bundle.
; Classification must honor the leaf contract on both the call site and the
; direct callee, so neither form can replace a real poll or satisfy coverage.

declare hotspotcc void @jeandle.safepoint_poll()
declare hotspotcc void @callsite_leaf()
declare hotspotcc void @callee_leaf() #0

attributes #0 = { "gc-leaf-function" }

define void @collapse_callsite_leaf() "java-method" {
entry:
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"() ]
  call hotspotcc void @callsite_leaf() #0 [ "deopt"() ]
  ret void
}

define void @collapse_callee_leaf() "java-method" {
entry:
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"() ]
  call hotspotcc void @callee_leaf() [ "deopt"() ]
  ret void
}

define void @loop_callsite_leaf_keeps_poll(ptr %flag) "java-method" {
entry:
  br label %header

header:
  %done = load i1, ptr %flag, align 1
  br i1 %done, label %exit, label %latch

latch:
  call hotspotcc void @callsite_leaf() #0 [ "deopt"() ]
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"() ]
  br label %header

exit:
  ret void
}

define void @loop_callee_leaf_keeps_poll(ptr %flag) "java-method" {
entry:
  br label %header

header:
  %done = load i1, ptr %flag, align 1
  br i1 %done, label %exit, label %latch

latch:
  call hotspotcc void @callee_leaf() [ "deopt"() ]
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"() ]
  br label %header

exit:
  ret void
}

define void @uncovered_callsite_leaf_loop(ptr %flag) "java-method" {
entry:
  br label %header

header:
  %done = load i1, ptr %flag, align 1
  br i1 %done, label %exit, label %latch

latch:
  call hotspotcc void @callsite_leaf() #0 [ "deopt"() ]
  br label %header

exit:
  ret void
}

define void @uncovered_callee_leaf_loop(ptr %flag) "java-method" {
entry:
  br label %header

header:
  %done = load i1, ptr %flag, align 1
  br i1 %done, label %exit, label %latch

latch:
  call hotspotcc void @callee_leaf() [ "deopt"() ]
  br label %header

exit:
  ret void
}

!java-method-compilation = !{}

; ELIM-LABEL: @collapse_callsite_leaf(
; ELIM:       call hotspotcc void @jeandle.safepoint_poll()
; ELIM:       call hotspotcc void @callsite_leaf()
; ELIM-LABEL: @collapse_callee_leaf(
; ELIM:       call hotspotcc void @jeandle.safepoint_poll()
; ELIM:       call hotspotcc void @callee_leaf()
; ELIM-LABEL: @loop_callsite_leaf_keeps_poll(
; ELIM:       call hotspotcc void @callsite_leaf()
; ELIM:       call hotspotcc void @jeandle.safepoint_poll()
; ELIM-LABEL: @loop_callee_leaf_keeps_poll(
; ELIM:       call hotspotcc void @callee_leaf()
; ELIM:       call hotspotcc void @jeandle.safepoint_poll()

; CALLSITE-ABORT: SafepointCoverageVerifier: loop with header 'header' in function 'uncovered_callsite_leaf_loop' has an uncovered backedge path and no provable trip bound
; CALLSITE-ABORT: Jeandle safepoint coverage verification failed
; CALLEE-ABORT: SafepointCoverageVerifier: loop with header 'header' in function 'uncovered_callee_leaf_loop' has an uncovered backedge path and no provable trip bound
; CALLEE-ABORT: Jeandle safepoint coverage verification failed
