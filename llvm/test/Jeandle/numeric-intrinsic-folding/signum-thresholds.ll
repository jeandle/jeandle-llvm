; RUN: opt -S -verify-each -passes='numeric-intrinsic-folding,instcombine' %s | FileCheck %s
; RUN: opt -S -verify-each -passes='numeric-intrinsic-folding,numeric-intrinsic-folding,instcombine' %s | FileCheck %s
!java-method-compilation = !{}
declare double @llvm.copysign.f64(double, double)
declare float @llvm.copysign.f32(float, float)

define i1 @gt_half(float noundef %x) {
; CHECK-LABEL: @gt_half(
; CHECK-NOT: copysign
; CHECK-NOT: select
; CHECK: fcmp ogt float %x, 0.000000e+00
  %z = fcmp ueq float %x, 0.0
  %c = call float @llvm.copysign.f32(float 1.0, float %x)
  %s = select i1 %z, float %x, float %c
  %r = fcmp ogt float %s, 0.5
  ret i1 %r
}

define i1 @lt_half(double noundef %x) {
; CHECK-LABEL: @lt_half(
; CHECK-NOT: copysign
; CHECK-NOT: select
; CHECK: fcmp ole double %x, 0.000000e+00
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp olt double %s, 0.5
  ret i1 %r
}

define i1 @gt_negative_half(double noundef %x) {
; CHECK-LABEL: @gt_negative_half(
; CHECK-NOT: copysign
; CHECK-NOT: select
; CHECK: fcmp oge double %x, 0.000000e+00
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp ogt double %s, -0.5
  ret i1 %r
}

define i1 @eq_half(float noundef %x) {
; CHECK-LABEL: @eq_half(
; CHECK-NOT: copysign
; CHECK-NOT: select
; CHECK: ret i1 false
  %z = fcmp ueq float %x, 0.0
  %c = call float @llvm.copysign.f32(float 1.0, float %x)
  %s = select i1 %z, float %x, float %c
  %r = fcmp oeq float %s, 0.5
  ret i1 %r
}

define i1 @ne_half(double noundef %x) {
; CHECK-LABEL: @ne_half(
; CHECK-NOT: copysign
; CHECK-NOT: select
; CHECK: ret i1 true
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp une double %s, 0.5
  ret i1 %r
}

define i1 @ge_minus_one(double noundef %x) {
; CHECK-LABEL: @ge_minus_one(
; CHECK-NOT: copysign
; CHECK-NOT: select
; CHECK: fcmp ord double %x, 0.000000e+00
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp oge double %s, -1.0
  ret i1 %r
}

define i1 @above_one(double noundef %x) {
; CHECK-LABEL: @above_one(
; CHECK-NOT: copysign
; CHECK-NOT: select
; CHECK: ret i1 false
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp ogt double %s, 1.0
  ret i1 %r
}

define i1 @unordered_below_minus_one(double noundef %x) {
; CHECK-LABEL: @unordered_below_minus_one(
; CHECK-NOT: copysign
; CHECK-NOT: select
; CHECK: fcmp uno double %x, 0.000000e+00
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp ult double %s, -1.0
  ret i1 %r
}

define i1 @unordered_half(float noundef %x) {
; CHECK-LABEL: @unordered_half(
; CHECK-NOT: copysign
; CHECK-NOT: select
; CHECK: fcmp ugt float %x, 0.000000e+00
  %z = fcmp ueq float %x, 0.0
  %c = call float @llvm.copysign.f32(float 1.0, float %x)
  %s = select i1 %z, float %x, float %c
  %r = fcmp ugt float %s, 0.5
  ret i1 %r
}

define i1 @swapped_half(double noundef %x) {
; CHECK-LABEL: @swapped_half(
; CHECK-NOT: copysign
; CHECK-NOT: select
; CHECK: fcmp ogt double %x, 0.000000e+00
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp olt double 0.5, %s
  ret i1 %r
}

define i1 @eq_nan(double noundef %x) {
; CHECK-LABEL: @eq_nan(
; CHECK-NOT: copysign
; CHECK-NOT: select
; CHECK: ret i1 false
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp oeq double %s, 0x7FF8000000000000
  ret i1 %r
}

define i1 @une_nan(double noundef %x) {
; CHECK-LABEL: @une_nan(
; CHECK-NOT: copysign
; CHECK-NOT: select
; CHECK: ret i1 true
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp une double %s, 0x7FF8000000000000
  ret i1 %r
}

define i1 @less_infinity(double noundef %x) {
; CHECK-LABEL: @less_infinity(
; CHECK-NOT: copysign
; CHECK-NOT: select
; CHECK: fcmp ord double %x, 0.000000e+00
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp olt double %s, 0x7FF0000000000000
  ret i1 %r
}

define i1 @above_negative_infinity(float noundef %x) {
; CHECK-LABEL: @above_negative_infinity(
; CHECK-NOT: copysign
; CHECK-NOT: select
; CHECK: fcmp ord float %x, 0.000000e+00
  %z = fcmp ueq float %x, 0.0
  %c = call float @llvm.copysign.f32(float 1.0, float %x)
  %s = select i1 %z, float %x, float %c
  %r = fcmp ogt float %s, 0xFFF0000000000000
  ret i1 %r
}
