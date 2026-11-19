; RUN: opt -S -verify-each -passes=numeric-intrinsic-folding %s | FileCheck %s
!java-method-compilation = !{}
declare double @llvm.copysign.f64(double, double)

; A poison-generating promise on any part of the apparent signum cannot
; justify bypassing a freeze observed elsewhere. Both consumers must agree
; on the sign of the same arbitrary frozen value.
define i64 @select_nnan(double noundef %x) {
; CHECK-LABEL: @select_nnan(
; CHECK: %f = freeze double %s
; CHECK: %r = call double @llvm.copysign.f64(double 2.000000e+00, double %f)
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select nnan i1 %z, double %x, double %c
  %f = freeze double %s
  %r = call double @llvm.copysign.f64(double 2.0, double %f)
  %fb = bitcast double %f to i64
  %rb = bitcast double %r to i64
  %different = xor i64 %fb, %rb
  %sign = lshr i64 %different, 63
  ret i64 %sign
}
define double @nested_select_nnan(double noundef %x) {
; CHECK-LABEL: @nested_select_nnan(
; CHECK: %f = freeze double %s
; CHECK: %ss = select i1 %zz, double %f, double %cc
; CHECK: ret double %ss
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select nnan i1 %z, double %x, double %c
  %f = freeze double %s
  %zz = fcmp ueq double %f, 0.0
  %cc = call double @llvm.copysign.f64(double 1.0, double %f)
  %ss = select i1 %zz, double %f, double %cc
  ret double %ss
}
define double @compare_nnan(double noundef %x) {
; CHECK-LABEL: @compare_nnan(
; CHECK: %f = freeze double %s
; CHECK: call double @llvm.copysign.f64(double 2.000000e+00, double %f)
  %z = fcmp nnan ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %f = freeze double %s
  %r = call double @llvm.copysign.f64(double 2.0, double %f)
  ret double %r
}
define double @copy_ninf(double noundef %x) {
; CHECK-LABEL: @copy_ninf(
; CHECK: %f = freeze double %s
; CHECK: call double @llvm.copysign.f64(double 2.000000e+00, double %f)
  %z = fcmp ueq double %x, 0.0
  %c = call ninf double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %f = freeze double %s
  %r = call double @llvm.copysign.f64(double 2.0, double %f)
  ret double %r
}
define double @return_class(double noundef %x) {
; CHECK-LABEL: @return_class(
; CHECK: %r = call double @llvm.copysign.f64(double 1.000000e+00, double %s)
  %z = fcmp ueq double %x, 0.0
  %c = call nofpclass(norm) double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = call double @llvm.copysign.f64(double 1.0, double %s)
  ret double %r
}

define double @signed_zero_annotation(double noundef %x) {
; CHECK-LABEL: @signed_zero_annotation(
; CHECK: %f = freeze double %s
; CHECK: %r = call double @llvm.copysign.f64(double 2.000000e+00, double %f)
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select nsz i1 %z, double %x, double %c
  %f = freeze double %s
  %r = call double @llvm.copysign.f64(double 2.0, double %f)
  ret double %r
}
define double @parameter_class(double noundef %x) {
; CHECK-LABEL: @parameter_class(
; CHECK: %r = call double @llvm.copysign.f64(double 1.000000e+00, double %s)
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double nofpclass(nan) %x)
  %s = select i1 %z, double %x, double %c
  %r = call double @llvm.copysign.f64(double 1.0, double %s)
  ret double %r
}
