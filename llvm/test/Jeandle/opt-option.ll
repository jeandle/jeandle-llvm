; RUN: opt -S --jeandle --print-pipeline-passes %s 2>&1 | FileCheck %s

; Combined pipeline: CHA devirtualization (from main) followed by the safepoint
; passes (Early poll elimination, strip mining, barrier insertion, loop-deletion
; poll elimination). CHECK-SAME matches relative order on the single printed
; pipeline line and tolerates the intermediate standard passes.
; CHECK: java-operation-lower<phase=0>
; CHECK-SAME: cha-devirtualization
; CHECK-SAME: jeandle-inline-driver
; CHECK-SAME: safepoint-poll-elimination
; CHECK-SAME: safepoint-strip-mining
; CHECK-SAME: safepoint-poll-elimination
; CHECK-SAME: insert-gc-barriers
; CHECK-SAME: safepoint-poll-elimination
; CHECK-SAME: java-operation-lower<phase=1>
; CHECK-SAME: expand-narrow-oop-cast
; CHECK-SAME: rewrite-statepoints-for-gc
; CHECK-SAME: jeandle-narrow-oop-marker
; CHECK-SAME: java-operation-lower<phase=9>
; CHECK-SAME: java-operation-deletion
; CHECK-SAME: tls-pointer-rewrite
; CHECK-SAME: instsimplify

define hotspotcc void @opt_option() {
entry:
  ret void
}
