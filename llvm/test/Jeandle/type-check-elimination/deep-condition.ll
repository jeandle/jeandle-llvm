; RUN: %python %S/Inputs/generate-deep-type-condition.py > %t.ll
; RUN: opt -S -verify-each -passes=type-check-elimination -jeandle-vm-callback-log=%S/Inputs/deep-condition.cblog %t.ll | FileCheck %s

; CHECK-LABEL: @deep(
; CHECK: %r = call i1 @jeandle.check_instanceof
; CHECK-LABEL: @typed_deep(
; CHECK: yes:
; CHECK-NEXT: ret i1 true
; CHECK-LABEL: @shallow(
; CHECK: yes:
; CHECK-NEXT: ret i1 true
