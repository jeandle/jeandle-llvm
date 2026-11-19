; RUN: opt -S -verify-each -passes=libm-identity-folding -jeandle-vm-callback-log=%S/Inputs/constant-eval.cblog %s | FileCheck %s
; Without a callback log only the exact identities apply; a non-trivial
; constant keeps its runtime call.
; RUN: opt -S -verify-each -passes=libm-identity-folding %s | FileCheck %s --check-prefix=NOLOG
;
; Constant arguments fold to the value the JVM reports for the selected
; runtime entry, so the result is bit-identical to interpreted execution by
; construction. The fixture values only exercise the mechanism; numeric
; truth is covered by jtreg against the real JVM.

!java-method-compilation = !{}

declare double @StubRoutines_dsin(double)
@SharedRuntime_dpow = alias double (double, double), ptr inttoptr (i64 4321 to ptr)

define double @sin_constant() {
; CHECK-LABEL: @sin_constant(
; CHECK-NEXT: ret double 0x3FE49D6E694619B8
; NOLOG-LABEL: @sin_constant(
; NOLOG: call double @StubRoutines_dsin(double {{.*}})
; NOLOG-NEXT: ret double %r
  %r = call double @StubRoutines_dsin(double 7.000000e-01)
  ret double %r
}

define double @pow_constants() {
; CHECK-LABEL: @pow_constants(
; CHECK-NEXT: ret double 0x4630000000000000
  %r = call double inttoptr (i64 4321 to ptr)(double 2.000000e+00, double 5.000000e-01)
  ret double %r
}
