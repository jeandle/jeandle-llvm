; RUN: opt -S --jeandle \
; RUN:   -jeandle-verify-safepoint-coverage=off \
; RUN:   -jeandle-enable-inclusive-loop-versioning --print-pipeline-passes %s 2>&1 \
; RUN:   | FileCheck %s --implicit-check-not='verify<jeandle-safepoint-coverage>' \
; RUN:                    --implicit-check-not='safepoint-poll-elimination<cleanup>'
; RUN: opt -S --jeandle \
; RUN:   -jeandle-enable-inclusive-loop-versioning \
; RUN:   -jeandle-verify-safepoint-coverage=warn --print-pipeline-passes %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=VERIFY \
; RUN:                    --implicit-check-not='safepoint-poll-elimination<cleanup>'
; RUN: opt -S --jeandle \
; RUN:   -jeandle-verify-safepoint-coverage=off \
; RUN:   -jeandle-enable-inclusive-loop-versioning=false \
; RUN:   --print-pipeline-passes %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=NO-INCLUSIVE \
; RUN:                    --implicit-check-not='safepoint-poll-elimination<cleanup>'
; RUN: opt -S --jeandle -jeandle-loop-strip-mining-iter=0 \
; RUN:   -jeandle-verify-safepoint-coverage=off \
; RUN:   --print-pipeline-passes %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=NO-STRIP \
; RUN:                    --implicit-check-not='safepoint-poll-elimination<cleanup>'
; RUN: opt -S -passes='jeandle<O0>' -jeandle-loop-strip-mining-iter=0 \
; RUN:   -jeandle-verify-safepoint-coverage=off \
; RUN:   --print-pipeline-passes %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=O0 \
; RUN:                    --implicit-check-not='safepoint-poll-elimination<cleanup>'

; The four-mode shape with Early repositioned to run AFTER the strip-mining
; canonicalization (SimplifyCFG, LoopSimplify/LCSSA, rotate/LICM), so it sees
; the most canonical loop form and no separate Cleanup pass is needed.
; InclusiveLoopVersioning and StripMining run after Early. With strip mining
; off, Early is preceded only by LoopSimplify, LCSSA and IndVarSimplify (so SCEV
; can bound int counted loops). At O3, LCSSA and atomic empty-loop deletion run
; after InsertGCBarriers. The verifier is wired after poll-removing phases when
; the check is warn or fatal (not off).

; CHECK-NOT:  function(loop-simplify)
; CHECK-NOT:  function(lcssa)
; CHECK:      loop-mssa(licm<no-allowspeculation>,loop-rotate<header-duplication;no-prepare-for-lto>,licm<allowspeculation>,indvars)
; CHECK-SAME: safepoint-poll-elimination<early;defer-empty-loop-deletion>
; CHECK-SAME: safepoint-strip-mining<inclusive-loop-versioning;defer-empty-loop-deletion>
; CHECK-SAME: safepoint-strip-mining<strip-mining;defer-empty-loop-deletion>
; CHECK-SAME: safepoint-poll-elimination<after-strip-mining;defer-empty-loop-deletion>
; CHECK-SAME: insert-gc-barriers
; CHECK-SAME: function(lcssa)
; CHECK-SAME: safepoint-poll-elimination<loop-deletion-prep>
; CHECK-SAME: java-operation-lower<phase=1>
; CHECK-SAME: expand-narrow-oop-cast
; CHECK-SAME: rewrite-statepoints-for-gc
; CHECK-SAME: jeandle-narrow-oop-marker
; CHECK-SAME: java-operation-lower<phase=9>
; CHECK-SAME: java-operation-deletion
; CHECK-SAME: tls-pointer-rewrite
; VERIFY-NOT:  function(loop-simplify)
; VERIFY-NOT:  function(lcssa)
; VERIFY:      loop-mssa(licm<no-allowspeculation>,loop-rotate<header-duplication;no-prepare-for-lto>,licm<allowspeculation>,indvars)
; VERIFY-SAME: safepoint-poll-elimination<early;defer-empty-loop-deletion>
; VERIFY-SAME: verify<jeandle-safepoint-coverage>
; VERIFY-SAME: safepoint-strip-mining<inclusive-loop-versioning;defer-empty-loop-deletion>
; VERIFY-SAME: safepoint-strip-mining<strip-mining;defer-empty-loop-deletion>
; VERIFY-SAME: safepoint-poll-elimination<after-strip-mining;defer-empty-loop-deletion>
; VERIFY-SAME: verify<jeandle-safepoint-coverage>
; VERIFY-SAME: insert-gc-barriers
; VERIFY-SAME: function(lcssa)
; VERIFY-SAME: safepoint-poll-elimination<loop-deletion-prep>
; VERIFY-SAME: java-operation-lower<phase=1>
; VERIFY-SAME: expand-narrow-oop-cast
; VERIFY-SAME: rewrite-statepoints-for-gc
; VERIFY-SAME: jeandle-narrow-oop-marker
; VERIFY-SAME: java-operation-lower<phase=9>
; VERIFY-SAME: java-operation-deletion
; VERIFY-SAME: tls-pointer-rewrite
; NO-INCLUSIVE-NOT:  function(loop-simplify)
; NO-INCLUSIVE-NOT:  function(lcssa)
; NO-INCLUSIVE:      loop-mssa(licm<no-allowspeculation>,loop-rotate<header-duplication;no-prepare-for-lto>,licm<allowspeculation>,indvars)
; NO-INCLUSIVE-SAME: safepoint-poll-elimination<early;defer-empty-loop-deletion>
; NO-INCLUSIVE-NOT:  safepoint-strip-mining<inclusive-loop-versioning>
; NO-INCLUSIVE-SAME: safepoint-strip-mining<strip-mining;defer-empty-loop-deletion>
; NO-INCLUSIVE-SAME: safepoint-poll-elimination<after-strip-mining;defer-empty-loop-deletion>
; NO-INCLUSIVE-SAME: insert-gc-barriers
; NO-INCLUSIVE-SAME: function(lcssa)
; NO-INCLUSIVE-SAME: safepoint-poll-elimination<loop-deletion-prep>
; NO-INCLUSIVE-SAME: java-operation-lower<phase=1>
; NO-STRIP-NOT:  function(loop-simplify)
; NO-STRIP-NOT:  function(lcssa)
; NO-STRIP:      function(loop(indvars)),function(safepoint-poll-elimination<early;defer-empty-loop-deletion>)
; NO-STRIP-NOT:  function(simplifycfg
; NO-STRIP-NOT:  loop-mssa(
; NO-STRIP-NOT:  safepoint-strip-mining<inclusive-loop-versioning>
; NO-STRIP-NOT:  safepoint-strip-mining<strip-mining>
; NO-STRIP-SAME: insert-gc-barriers
; NO-STRIP-SAME: function(lcssa)
; NO-STRIP-SAME: safepoint-poll-elimination<loop-deletion-prep>
; NO-STRIP-SAME: java-operation-lower<phase=1>
; O0-NOT: function(loop-simplify)
; O0-NOT: function(lcssa)
; O0: function(loop(indvars)),function(safepoint-poll-elimination<early>)
; O0-NOT: loop-mssa(
; O0-NOT: safepoint-strip-mining<inclusive-loop-versioning>
; O0-NOT: safepoint-strip-mining<strip-mining>
; O0-SAME: insert-gc-barriers
; O0-NOT: function(lcssa)
; O0-NOT: safepoint-poll-elimination<loop-deletion-prep>
; O0-SAME: java-operation-lower<phase=1>

define hotspotcc void @f() {
entry:
  ret void
}
