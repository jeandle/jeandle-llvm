; RUN: opt -S --jeandle --print-pipeline-passes %s 2>&1 | FileCheck %s --check-prefix=PEA-ON
; RUN: opt -S --jeandle --jeandle-pea-iterations=0 --print-pipeline-passes %s 2>&1 | FileCheck %s --check-prefix=PEA-OFF

; JavaOp lowering, the shared stage-[4] loop cluster, and PostTransform run
; before the optional PEA pass. Only PartialEscapeIterative is gated on
; -jeandle-pea-iterations > 0.

; Keep these as separate ordered checks: LLVM prints pass parameters, and
; target-specific passes can be inserted between the semantic stages.
; PEA-ON: {{.*jeandle-inline-driver,}}
; PEA-ON: function(java-op-length-folding),java-operation-lower<phase=1>,
; PEA-ON-SAME: function(loop-mssa(loop-rotate
; PEA-ON-SAME: function(loop-mssa(indvars,loop-idiom,loop-deletion),loop-unroll
; PEA-ON-SAME: function(adce{{.*}}),function(safepoint-poll-elimination<post-transform>),function(partial-escape-iterative),
; PEA-ON-SAME: function(instsimplify),function(recover-type-info),
; PEA-ON-SAME: function(type-check-elimination),function(repeated-constant-field-folding),function(arraycopy-specialization),function(type-check-elimination),
; PEA-ON-SAME: function(early-cse<>),function(instcombine
; PEA-ON-SAME: function(simplifycfg
; PEA-ON-SAME: function(loop-mssa(loop-rotate
; PEA-ON-SAME: function(safepoint-poll-elimination<early
; PEA-ON-SAME: function(insert-gc-barriers),
; PEA-ON-SAME: java-operation-lower<phase=2>,

; With PEA disabled, the same shared stage-[4] cluster and PostTransform run;
; only PartialEscapeIterative is omitted.
; PEA-OFF: {{.*jeandle-inline-driver,}}
; PEA-OFF: function(java-op-length-folding),java-operation-lower<phase=1>,
; PEA-OFF-SAME: function(loop-mssa(loop-rotate
; PEA-OFF-SAME: function(loop-mssa(indvars,loop-idiom,loop-deletion),loop-unroll
; PEA-OFF-SAME: function(safepoint-poll-elimination<post-transform>),
; PEA-OFF-SAME: function(instsimplify),function(recover-type-info),
; PEA-OFF-NOT: partial-escape-iterative
; PEA-OFF: function(safepoint-poll-elimination<early
; PEA-OFF-SAME: {{.*function\(insert-gc-barriers\),}}
; PEA-OFF-SAME: {{.*java-operation-lower\<phase=2\>,}}

define hotspotcc void @pipeline_gate() {
entry:
  ret void
}
