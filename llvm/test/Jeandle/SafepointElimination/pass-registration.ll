; RUN: opt -passes=safepoint-poll-elimination -S < %s | FileCheck %s
; RUN: opt -passes='safepoint-poll-elimination<early>' -S < %s | FileCheck %s
; RUN: opt -passes='safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' \
; RUN:   -S < %s | FileCheck %s
; RUN: opt --print-passes | FileCheck %s --check-prefix=PRINT

; The pass resolves by name as a function pass and leaves IR intact.

declare hotspotcc void @jeandle.safepoint_poll()

define void @f() "java-method" gc "no-op" {
entry:
  call hotspotcc void @jeandle.safepoint_poll()
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @f(
; CHECK: call hotspotcc void @jeandle.safepoint_poll()
; PRINT-DAG: safepoint-poll-elimination<early;after-strip-mining;loop-deletion-prep;defer-empty-loop-deletion>
; PRINT-DAG: safepoint-strip-mining<inclusive-loop-versioning;strip-mining;defer-empty-loop-deletion>
