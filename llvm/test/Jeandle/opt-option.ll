; RUN: opt -S --jeandle --print-pipeline-passes %s 2>&1 | FileCheck %s

; CHECK: {{.*java-operation-lower\<phase=0\>.*java-operation-lower\<phase=1\>.*tls-pointer-rewrite.*rewrite-statepoints-for-gc.*}}

define hotspotcc void @opt_option() {
entry:
  ret void
}
