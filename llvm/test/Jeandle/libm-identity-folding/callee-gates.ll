; RUN: split-file %s %t
; RUN: opt -S -verify-each -passes=libm-identity-folding %t/no-mark.ll | FileCheck %s --check-prefix=NO-MARK
; RUN: opt -S -verify-each -passes=libm-identity-folding %t/constraints.ll | FileCheck %s
; RUN: opt -S -verify-each -passes=libm-identity-folding %t/signature.ll | FileCheck %s --check-prefix=SIGNATURE

;--- no-mark.ll
declare double @StubRoutines_dsin(double)
define double @no_mark() {
; NO-MARK-LABEL: @no_mark(
; NO-MARK: call double @StubRoutines_dsin(double 0.000000e+00)
  %r = call double @StubRoutines_dsin(double 0.0)
  ret double %r
}

;--- constraints.ll
!java-method-compilation = !{}
declare double @StubRoutines_dsin(double)
declare double @StubRoutines_dpow(double, double)
declare i32 @personality(...)
define double @tail(double %x) {
; CHECK-LABEL: @tail(
; CHECK: musttail call double @StubRoutines_dsin(double 0.000000e+00)
  %r = musttail call double @StubRoutines_dsin(double 0.0)
  ret double %r
}
define double @bundled_pow(double %x) {
; CHECK-LABEL: @bundled_pow(
; CHECK: call double @StubRoutines_dpow{{.*}}[ "deopt"
  %r = call double @StubRoutines_dpow(double %x, double 0.0) [ "deopt"(i32 1) ]
  ret double %r
}
define double @invoked() personality ptr @personality {
; CHECK-LABEL: @invoked(
; CHECK: invoke double @StubRoutines_dsin
  %r = invoke double @StubRoutines_dsin(double 0.0) to label %normal unwind label %unwind
normal:
  ret double %r
unwind:
  %lp = landingpad { ptr, i32 } cleanup
  resume { ptr, i32 } %lp
}

;--- signature.ll
!java-method-compilation = !{}
define double @StubRoutines_dsin(double %x) {
  ret double 7.0
}
declare double @StubRoutines_dcos(double, ...)
@SharedRuntime_dexp = alias double (double, double), ptr inttoptr (i64 99 to ptr)
define double @defined_stub() {
; SIGNATURE-LABEL: @defined_stub(
; SIGNATURE: call double @StubRoutines_dsin
  %r = call double @StubRoutines_dsin(double 0.0)
  ret double %r
}
define double @vararg_stub() {
; SIGNATURE-LABEL: @vararg_stub(
; SIGNATURE: call double (double, ...) @StubRoutines_dcos
  %r = call double (double, ...) @StubRoutines_dcos(double 0.0)
  ret double %r
}
define double @wrong_alias_type() {
; SIGNATURE-LABEL: @wrong_alias_type(
; SIGNATURE: call double inttoptr (i64 99 to ptr)(double 0.000000e+00)
  %r = call double inttoptr (i64 99 to ptr)(double 0.0)
  ret double %r
}
