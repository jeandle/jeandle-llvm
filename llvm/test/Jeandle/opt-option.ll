; RUN: opt -S --jeandle --print-pipeline-passes %s 2>&1 | FileCheck %s

; CHECK: {{.*java-operation-lower\<phase=0\>.*constant-field-folding.*java-operation-lower\<phase=1\>.*rewrite-statepoints-for-gc.*java-operation-lower\<phase=9\>.*tls-pointer-rewrite.*instsimplify.*}}

define hotspotcc void @opt_option() {
entry:
  ret void
}
