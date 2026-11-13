; RUN: opt -S -verify-each -passes='libm-identity-folding,instcombine,simplifycfg,libm-identity-folding' %s | FileCheck %s
!java-method-compilation = !{}
declare double @StubRoutines_dsin(double)
@SharedRuntime_dsin = alias ptr, inttoptr (i64 5154 to ptr)

define double @sin_stub_positive() {
; CHECK-LABEL: @sin_stub_positive(
; CHECK-NEXT: ret double 0.000000e+00
  %r = call double @StubRoutines_dsin(double 0.0)
  ret double %r
}

define double @sin_stub_negative() {
; CHECK-LABEL: @sin_stub_negative(
; CHECK-NEXT: ret double -0.000000e+00
  %r = call double @StubRoutines_dsin(double -0.0)
  ret double %r
}

define double @sin_shared_positive() {
; CHECK-LABEL: @sin_shared_positive(
; CHECK-NEXT: ret double 0.000000e+00
  %r = call double @SharedRuntime_dsin(double 0.0)
  ret double %r
}

define double @sin_shared_negative() {
; CHECK-LABEL: @sin_shared_negative(
; CHECK-NEXT: ret double -0.000000e+00
  %r = call double @SharedRuntime_dsin(double -0.0)
  ret double %r
}
declare double @StubRoutines_dcos(double)
@SharedRuntime_dcos = alias ptr, inttoptr (i64 5138 to ptr)

define double @cos_stub_positive() {
; CHECK-LABEL: @cos_stub_positive(
; CHECK-NEXT: ret double 1.000000e+00
  %r = call double @StubRoutines_dcos(double 0.0)
  ret double %r
}

define double @cos_stub_negative() {
; CHECK-LABEL: @cos_stub_negative(
; CHECK-NEXT: ret double 1.000000e+00
  %r = call double @StubRoutines_dcos(double -0.0)
  ret double %r
}

define double @cos_shared_positive() {
; CHECK-LABEL: @cos_shared_positive(
; CHECK-NEXT: ret double 1.000000e+00
  %r = call double @SharedRuntime_dcos(double 0.0)
  ret double %r
}

define double @cos_shared_negative() {
; CHECK-LABEL: @cos_shared_negative(
; CHECK-NEXT: ret double 1.000000e+00
  %r = call double @SharedRuntime_dcos(double -0.0)
  ret double %r
}
declare double @StubRoutines_dtan(double)
@SharedRuntime_dtan = alias ptr, inttoptr (i64 5155 to ptr)

define double @tan_stub_positive() {
; CHECK-LABEL: @tan_stub_positive(
; CHECK-NEXT: ret double 0.000000e+00
  %r = call double @StubRoutines_dtan(double 0.0)
  ret double %r
}

define double @tan_stub_negative() {
; CHECK-LABEL: @tan_stub_negative(
; CHECK-NEXT: ret double -0.000000e+00
  %r = call double @StubRoutines_dtan(double -0.0)
  ret double %r
}

define double @tan_shared_positive() {
; CHECK-LABEL: @tan_shared_positive(
; CHECK-NEXT: ret double 0.000000e+00
  %r = call double @SharedRuntime_dtan(double 0.0)
  ret double %r
}

define double @tan_shared_negative() {
; CHECK-LABEL: @tan_shared_negative(
; CHECK-NEXT: ret double -0.000000e+00
  %r = call double @SharedRuntime_dtan(double -0.0)
  ret double %r
}
declare double @StubRoutines_dlog(double)
@SharedRuntime_dlog = alias ptr, inttoptr (i64 5147 to ptr)

define double @log_stub_positive() {
; CHECK-LABEL: @log_stub_positive(
; CHECK-NEXT: ret double 0.000000e+00
  %r = call double @StubRoutines_dlog(double 1.0)
  ret double %r
}

define double @log_shared_positive() {
; CHECK-LABEL: @log_shared_positive(
; CHECK-NEXT: ret double 0.000000e+00
  %r = call double @SharedRuntime_dlog(double 1.0)
  ret double %r
}
declare double @StubRoutines_dlog10(double)
@SharedRuntime_dlog10 = alias ptr, inttoptr (i64 5173 to ptr)

define double @log10_stub_positive() {
; CHECK-LABEL: @log10_stub_positive(
; CHECK-NEXT: ret double 0.000000e+00
  %r = call double @StubRoutines_dlog10(double 1.0)
  ret double %r
}

define double @log10_shared_positive() {
; CHECK-LABEL: @log10_shared_positive(
; CHECK-NEXT: ret double 0.000000e+00
  %r = call double @SharedRuntime_dlog10(double 1.0)
  ret double %r
}
declare double @StubRoutines_dexp(double)
@SharedRuntime_dexp = alias ptr, inttoptr (i64 5140 to ptr)

define double @exp_stub_positive() {
; CHECK-LABEL: @exp_stub_positive(
; CHECK-NEXT: ret double 1.000000e+00
  %r = call double @StubRoutines_dexp(double 0.0)
  ret double %r
}

define double @exp_stub_negative() {
; CHECK-LABEL: @exp_stub_negative(
; CHECK-NEXT: ret double 1.000000e+00
  %r = call double @StubRoutines_dexp(double -0.0)
  ret double %r
}

define double @exp_shared_positive() {
; CHECK-LABEL: @exp_shared_positive(
; CHECK-NEXT: ret double 1.000000e+00
  %r = call double @SharedRuntime_dexp(double 0.0)
  ret double %r
}

define double @exp_shared_negative() {
; CHECK-LABEL: @exp_shared_negative(
; CHECK-NEXT: ret double 1.000000e+00
  %r = call double @SharedRuntime_dexp(double -0.0)
  ret double %r
}

declare double @StubRoutines_dpow(double, double)
@SharedRuntime_dpow = alias ptr, inttoptr (i64 4321 to ptr)
define double @shared_reciprocal(double noundef %x) {
; CHECK-LABEL: @shared_reciprocal(
; CHECK: fcmp ord double %x,
; CHECK: fdiv double 1.000000e+00, %x
; CHECK: call double inttoptr (i64 4321 to ptr)
; CHECK: ret double
  %r = call double inttoptr (i64 4321 to ptr)(double %x, double -1.0)
  ret double %r
}
define double @stub_reciprocal(double %x) {
; CHECK-LABEL: @stub_reciprocal(
; CHECK-NEXT: %r = call double @StubRoutines_dpow(double %x, double -1.000000e+00)
  %r = call double @StubRoutines_dpow(double %x, double -1.0)
  ret double %r
}
define double @bundled_constant() {
; CHECK-LABEL: @bundled_constant(
; CHECK: call double @StubRoutines_dsin{{.*}}[ "deopt"
  %r = call double @StubRoutines_dsin(double 0.0) [ "deopt"(i32 1) ]
  ret double %r
}
define double @ordinary_argument(double %x) {
; CHECK-LABEL: @ordinary_argument(
; CHECK: call double @StubRoutines_dsin(double %x)
  %r = call double @StubRoutines_dsin(double %x)
  ret double %r
}

define double @square_definedness(double %x) {
; CHECK-LABEL: @square_definedness(
; CHECK: %[[X:.*]] = freeze double %x
; CHECK: fmul double %[[X]], %[[X]]
  %r = call double @StubRoutines_dpow(double %x, double 2.0)
  ret double %r
}
