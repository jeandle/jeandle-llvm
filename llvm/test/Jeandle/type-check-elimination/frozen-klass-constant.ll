; RUN: opt -S -verify-each -passes=type-check-elimination -jeandle-vm-callback-log=%S/Inputs/frozen-klass-constant.cblog %s | FileCheck %s

target datalayout = "e-p:64:64"
@slot = internal constant ptr inttoptr (i64 9 to ptr)
declare i1 @jeandle.check_klass_subtype(ptr, ptr)

define i2 @keep_frozen_klass() {
entry:
  %v = load ptr, ptr @slot, !align !0
  %f = freeze ptr %v
  %is_one = icmp eq ptr %f, inttoptr (i64 1 to ptr)
  br i1 %is_one, label %one, label %other
one:
  %r = call i1 @jeandle.check_klass_subtype(ptr %f, ptr inttoptr (i64 9 to ptr))
  %result = zext i1 %r to i2
  ret i2 %result
other:
  ret i2 2
}
; CHECK-LABEL: @keep_frozen_klass(
; CHECK: %r = call i1 @jeandle.check_klass_subtype(ptr %f,
; CHECK: %result = zext i1 %r to i2

define i1 @fold_defined_klass() {
  %v = load ptr, ptr @slot, !noundef !1
  %f = freeze ptr %v
  %r = call i1 @jeandle.check_klass_subtype(ptr %f, ptr inttoptr (i64 9 to ptr))
  ret i1 %r
}
; CHECK-LABEL: @fold_defined_klass(
; CHECK: ret i1 true

!0 = !{i64 16}
!1 = !{}
!java-method-compilation = !{}
