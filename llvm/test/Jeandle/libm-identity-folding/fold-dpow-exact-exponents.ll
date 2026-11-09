; RUN: opt -S -passes=libm-identity-folding %s | FileCheck %s --check-prefixes=COMMON,FOLD
; RUN: opt -S -passes=instcombine,libm-identity-folding %s | FileCheck %s --check-prefixes=COMMON,PHI

; Exact-exponent identity folding for the HotSpot runtime dpow calls the
; Jeandle frontend emits for Math.pow while JeandleUseHotspotIntrinsics is
; on. The call is opaque to LLVM's own libcall machinery, so these exact
; identities would otherwise be unreachable in the default configuration.
;
; Only identities that are bit-exact against BOTH runtime entries (the
; fdlibm port behind SharedRuntime::dpow and the x86 libm stub behind
; StubRoutines::dpow) on every input -- signed zeros, infinities, and NaN
; payloads including signaling-NaN quieting -- are folded:
;   dpow(x, 2.0)   -> x * x   (fdlibm returns x*x for y==2 before any range
;                              reduction; the x86 stub multiplies at entry;
;                              one correctly rounded multiply quiets sNaN
;                              the same way both entries do)
;   dpow(x, +-0.0) -> 1.0     (fdlibm tests (iy|ly)==0 first, so even a NaN
;                              base yields 1.0; IEEE pow(x,+-0)=1 for all x)
; Deliberately NOT folded:
;   y == 1.0 -> x      the runtime quiets a signaling-NaN base, x would not
;   y == -1.0 / 0.5 / anything else: no bit-exact identity. The guarded
;   sqrt specialization for y == 0.5 is built by the frontend, which can
;   create the required control flow.
;
; The pass relies on earlier passes to reveal constant exponents: it does
; not look through selects/PHIs itself (the second RUN line shows instcombine
; exposing the constant first, then the identity folding applying).

!java-method-compilation = !{}

declare double @StubRoutines_dpow(double, double)

; The SharedRuntime form is an absolute address; the JVM emits a module
; alias naming it, while the call's callee operand is the aliasee constant.
@SharedRuntime_dpow = alias double (double, double), ptr inttoptr (i64 4321 to ptr)

define double @stub_square(double %x) {
; COMMON-LABEL: define double @stub_square(
; COMMON-NEXT: %[[MUL:.*]] = fmul double %x, %x
; COMMON-NEXT: ret double %[[MUL]]
  %r = call double @StubRoutines_dpow(double %x, double 2.000000e+00)
  ret double %r
}

define double @stub_zero_exponent(double %x) {
; COMMON-LABEL: define double @stub_zero_exponent(
; COMMON-NEXT: ret double 1.000000e+00
  %r = call double @StubRoutines_dpow(double %x, double 0.000000e+00)
  ret double %r
}

define double @stub_negative_zero_exponent(double %x) {
; COMMON-LABEL: define double @stub_negative_zero_exponent(
; COMMON-NEXT: ret double 1.000000e+00
  %r = call double @StubRoutines_dpow(double %x, double -0.000000e+00)
  ret double %r
}

define double @shared_square(double %x) {
; COMMON-LABEL: define double @shared_square(
; COMMON-NEXT: %[[MUL2:.*]] = fmul double %x, %x
; COMMON-NEXT: ret double %[[MUL2]]
  %r = call double inttoptr (i64 4321 to ptr)(double %x, double 2.000000e+00)
  ret double %r
}

define double @no_fold_exponent_one(double %x) {
; The runtime quiets a signaling-NaN base for y==1.0; returning x unchanged
; would differ in NaN payload bits.
; COMMON-LABEL: define double @no_fold_exponent_one(
; COMMON: call double @StubRoutines_dpow(double %x, double 1.000000e+00)
; COMMON: ret double
  %r = call double @StubRoutines_dpow(double %x, double 1.000000e+00)
  ret double %r
}

define double @no_fold_exponent_half(double %x) {
; COMMON-LABEL: define double @no_fold_exponent_half(
; COMMON: call double @StubRoutines_dpow(double %x, double 5.000000e-01)
; COMMON: ret double
  %r = call double @StubRoutines_dpow(double %x, double 5.000000e-01)
  ret double %r
}

define double @no_fold_exponent_minus_one(double %x) {
; No fold: the fdlibm port shortcuts to one/x, but the x86 stub has no
; y==-1 entry shortcut, so 1/x is not bit-exact against both runtime entries.
; COMMON-LABEL: define double @no_fold_exponent_minus_one(
; COMMON: call double @StubRoutines_dpow(double %x, double -1.000000e+00)
; COMMON: ret double
  %r = call double @StubRoutines_dpow(double %x, double -1.000000e+00)
  ret double %r
}

define double @no_fold_exponent_minus_two(double %x) {
; COMMON-LABEL: define double @no_fold_exponent_minus_two(
; COMMON: call double @StubRoutines_dpow(double %x, double -2.000000e+00)
; COMMON: ret double
  %r = call double @StubRoutines_dpow(double %x, double -2.000000e+00)
  ret double %r
}

define double @no_fold_symbolic_exponent(double %x, double %y) {
; COMMON-LABEL: define double @no_fold_symbolic_exponent(
; COMMON: call double @StubRoutines_dpow(double %x, double %y)
; COMMON: ret double
  %r = call double @StubRoutines_dpow(double %x, double %y)
  ret double %r
}

define double @select_hidden_exponent(double %x, i1 %cond) {
; Without a prior simplification the exponent is a select, not a constant:
; the pass keeps the call.
; FOLD-LABEL: define double @select_hidden_exponent(
; FOLD: call double @StubRoutines_dpow
; FOLD: ret double
; Once instcombine has collapsed the select to 2.0, the identity applies.
; PHI-LABEL: define double @select_hidden_exponent(
; PHI-NEXT: %[[MUL3:.*]] = fmul double %x, %x
; PHI-NEXT: ret double %[[MUL3]]
  %e = select i1 %cond, double 2.000000e+00, double 2.000000e+00
  %r = call double @StubRoutines_dpow(double %x, double %e)
  ret double %r
}
