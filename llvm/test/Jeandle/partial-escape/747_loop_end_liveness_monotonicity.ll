; REQUIRES: asserts
; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-pea-analyze-function=loop_end_liveness_monotonicity \
; RUN:   %s | FileCheck %s --check-prefix=IR
; RUN: opt -disable-output -verify-each \
; RUN:   -passes="require<partial-escape-analysis>" \
; RUN:   -jeandle-pea-analyze-function=loop_end_liveness_monotonicity \
; RUN:   -jeandle-dump-pea-stats -debug-only=partial-escape-analysis \
; RUN:   %s 2>&1 | FileCheck %s --check-prefix=DEBUG \
; RUN:     --implicit-check-not='loop traversal incomplete' \
; RUN:     --implicit-check-not='loop-end liveness monotonicity violation'

; The preheader byte field starts at zero and is the switch condition, so the
; first seeded body traversal publishes only zero.latch as a live loop end.
; That latch writes one, making B' a loop-carried field PHI.  The retry sees a
; nonconstant condition, publishes both structural ends, and converges while
; keeping the object and all of its field accesses virtual.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

define i8 @loop_end_liveness_monotonicity(i1 %done)
    gc "hotspotgc" personality ptr null {
entry:
  %object = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74701 to ptr), i32 16, i1 false)
  %entry.field = getelementptr i8, ptr addrspace(1) %object, i64 8
  store atomic i8 0, ptr addrspace(1) %entry.field unordered, align 1
  br label %loop.preheader

loop.preheader:
  br label %loop.header

loop.header:
  %field = getelementptr i8, ptr addrspace(1) %object, i64 8
  %current = load atomic i8, ptr addrspace(1) %field unordered, align 1
  switch i8 %current, label %nonzero.latch [
    i8 0, label %zero.latch
  ]

zero.latch:
  store atomic i8 1, ptr addrspace(1) %field unordered, align 1
  br i1 %done, label %exit, label %loop.header

nonzero.latch:
  br i1 %done, label %exit, label %loop.header

exit:
  %result = load atomic i8, ptr addrspace(1) %field unordered, align 1
  ret i8 %result
}

; IR-LABEL: define i8 @loop_end_liveness_monotonicity(
; IR-NOT: jeandle.new_instance
; IR-NOT: load atomic
; IR-NOT: store atomic
; IR: loop.header:
; IR-NEXT: [[HEADER:%pea.field.phi[^ ]*]] = phi i8
; IR-NEXT: [[COND:%.*]] = icmp eq i8 [[HEADER]], 0
; IR-NEXT: br i1 [[COND]], label %zero.latch, label %nonzero.latch
; IR-NOT: load atomic
; IR-NOT: store atomic
; IR: zero.latch:
; IR-NOT: store atomic
; IR: br i1 %done, label %exit, label %loop.header
; IR: nonzero.latch:
; IR-NOT: store atomic
; IR: br i1 %done, label %exit, label %loop.header
; IR: exit:
; IR-NEXT: [[RESULT:%pea.field.phi[^ ]*]] = phi i8 [ [[HEADER]], %nonzero.latch ], [ 1, %zero.latch ]
; IR-NEXT: ret i8 [[RESULT]]
; IR-NOT: jeandle.new_instance
; IR-NOT: load atomic
; IR-NOT: store atomic
; IR: }

; DEBUG-DAG: PEA: loop @ loop.header iteration 1 backedge %zero.latch is live
; DEBUG-DAG: PEA: loop @ loop.header iteration 1 backedge %nonzero.latch is dead
; DEBUG: PEA: loop @ loop.header retry after 1 iters (B != B')
; DEBUG-DAG: PEA: loop @ loop.header iteration 2 backedge %zero.latch is live
; DEBUG-DAG: PEA: loop @ loop.header iteration 2 backedge %nonzero.latch is live
; DEBUG-NEXT: PEA: loop @ loop.header converged in 2 iters (B-based, post-body)
; DEBUG: ;; PEA stats @loop_end_liveness_monotonicity: NeverEscapes=1 PartiallyEscapes=0 AlwaysEscapes=0

!java-method-compilation = !{}
