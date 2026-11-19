; RUN: opt -S -verify-each -passes=numeric-intrinsic-folding %s | FileCheck %s

declare i64 @jeandle.round.double(double) "lower-phase"="1"
declare double @llvm.copysign.f64(double, double)
define i64 @round_without_mark(i32 %x) {
; CHECK-LABEL: @round_without_mark(
; CHECK: %f = sitofp i32 %x to double
; CHECK: %r = call i64 @jeandle.round.double(double %f)
  %f = sitofp i32 %x to double
  %r = call i64 @jeandle.round.double(double %f)
  ret i64 %r
}
define i1 @signum_without_mark(double noundef %x) {
; CHECK-LABEL: @signum_without_mark(
; CHECK: %s = select i1 %z, double %x, double %c
; CHECK: %r = fcmp ogt double %s, 0.000000e+00
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp ogt double %s, 0.0
  ret i1 %r
}
