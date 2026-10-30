; RUN: opt -S --jeandle --print-pipeline-passes %s 2>&1 | FileCheck %s --check-prefix=LIFETIME
; RUN: opt -S --jeandle --print-pipeline-passes %s 2>&1 | FileCheck %s --check-prefix=ON
; RUN: opt -S --jeandle --jeandle-pea-iterations=0 --print-pipeline-passes %s 2>&1 | FileCheck %s --check-prefix=OFF
; ON: function(string-intrinsic-specialization),function(repeated-constant-field-folding)
; ON: partial-escape-iterative
; ON: function(string-intrinsic-specialization)
; ON: repeated-constant-field-folding
; ON: copy-specialization
; ON: insert-gc-barriers
; ON: globaldce,java-operation-lower<phase=1>
; OFF: function(string-intrinsic-specialization),function(repeated-constant-field-folding)
; OFF-NOT: partial-escape-iterative
; OFF: function(string-intrinsic-specialization)
; OFF: repeated-constant-field-folding
; OFF: copy-specialization
; OFF: insert-gc-barriers
; OFF: globaldce,java-operation-lower<phase=1>
; LIFETIME-NOT: globaldce
; LIFETIME: copy-specialization
; LIFETIME-NOT: globaldce
; LIFETIME: insert-gc-barriers
; LIFETIME: globaldce,java-operation-lower<phase=1>
define void @pipeline() { ret void }
