; RUN: opt -S --jeandle --print-pipeline-passes %s 2>&1 | FileCheck %s --check-prefix=PEA-ON
; RUN: opt -S --jeandle --jeandle-pea-iterations=0 --print-pipeline-passes %s 2>&1 | FileCheck %s --check-prefix=PEA-OFF

; The whole PEA segment — pre-PEA high-tier cluster, pre-PEA cleanup, PEA
; itself, and the post-PEA cleanup — is gated on -jeandle-pea-iterations > 0.

; Keep these as separate ordered checks: LLVM prints pass parameters, and
; target-specific passes can be inserted between the semantic stages.
; PEA-ON: {{.*jeandle-inline-driver,}}
; PEA-ON: function(java-op-length-folding,loop-simplify,
; PEA-ON: {{.*loop\(loop-rotate.*indvars,loop-deletion\),}}
; PEA-ON: loop-unroll<no-partial;no-runtime;no-upperbound;full-unroll-max=128;O3>,
; PEA-ON: {{.*function\(partial-escape-iterative\),}}
; PEA-ON: function(instsimplify),
; PEA-ON: function(recover-type-info),
; PEA-ON: function(type-check-elimination),
; PEA-ON: function(repeated-constant-field-folding),
; PEA-ON: {{.*function\(arraycopy-specialization\),}}
; PEA-ON: function(type-check-elimination),
; PEA-ON: {{.*function\(insert-gc-barriers\),}}
; PEA-ON: {{.*java-operation-lower\<phase=1\>,}}

; With PEA disabled the inline driver is followed directly by the standard
; post-inline cluster and insert-gc-barriers: no pre-PEA cluster, no cleanup,
; no PEA.
; PEA-OFF: {{.*jeandle-inline-driver,}}
; PEA-OFF: function(instsimplify),
; PEA-OFF: function(recover-type-info),
; PEA-OFF: function(type-check-elimination),
; PEA-OFF: function(repeated-constant-field-folding),
; PEA-OFF: {{.*function\(arraycopy-specialization\),}}
; PEA-OFF: {{.*function\(type-check-elimination\),}}
; PEA-OFF: {{.*function\(insert-gc-barriers\),}}
; PEA-OFF: {{.*java-operation-lower\<phase=1\>,}}

define hotspotcc void @pipeline_gate() {
entry:
  ret void
}
