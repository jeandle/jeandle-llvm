; RUN: opt -S -verify-each -passes='libm-identity-folding,instcombine,simplifycfg,libm-identity-folding,instcombine,simplifycfg' %s | FileCheck %s
!java-method-compilation = !{}
declare double @StubRoutines_dpow(double, double)
define double @positive_zero() {
; CHECK-LABEL: @positive_zero(
; CHECK-NEXT: ret double 0.000000e+00
  %r = call double @StubRoutines_dpow(double 0.0, double 0.5)
  ret double %r
}
define double @negative_zero() {
; CHECK-LABEL: @negative_zero(
; CHECK-NEXT: ret double 0.000000e+00
  %r = call double @StubRoutines_dpow(double -0.0, double 0.5)
  ret double %r
}
define double @negative_finite() {
; CHECK-LABEL: @negative_finite(
; CHECK: call double @StubRoutines_dpow(double -1.000000e+00, double 5.000000e-01)
  %r = call double @StubRoutines_dpow(double -1.0, double 0.5)
  ret double %r
}
