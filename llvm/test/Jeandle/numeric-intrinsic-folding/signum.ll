; RUN: opt -S -verify-each -passes='numeric-intrinsic-folding,instcombine' %s | FileCheck %s
; RUN: opt -S -verify-each -passes='numeric-intrinsic-folding,numeric-intrinsic-folding,instcombine' %s | FileCheck %s
!java-method-compilation = !{}
declare double @llvm.copysign.f64(double, double)
declare float @llvm.copysign.f32(float, float)

define i1 @positive_32(float noundef %x) {
; CHECK-LABEL: @positive_32(
; CHECK-NOT: copysign
; CHECK: fcmp ogt float %x, 0.000000e+00
  %z = fcmp ueq float %x, 0.0
  %c = call float @llvm.copysign.f32(float 1.0, float %x)
  %s = select i1 %z, float %x, float %c
  %r = fcmp ogt float %s, 0.0
  ret i1 %r
}

define i1 @negative_32(float noundef %x) {
; CHECK-LABEL: @negative_32(
; CHECK-NOT: copysign
; CHECK: fcmp olt float %x, 0.000000e+00
  %z = fcmp ueq float %x, 0.0
  %c = call float @llvm.copysign.f32(float 1.0, float %x)
  %s = select i1 %z, float %x, float %c
  %r = fcmp olt float %s, 0.0
  ret i1 %r
}

define i1 @is_one_32(float noundef %x) {
; CHECK-LABEL: @is_one_32(
; CHECK-NOT: copysign
; CHECK: fcmp ogt float %x, 0.000000e+00
  %z = fcmp ueq float %x, 0.0
  %c = call float @llvm.copysign.f32(float 1.0, float %x)
  %s = select i1 %z, float %x, float %c
  %r = fcmp oeq float %s, 1.0
  ret i1 %r
}

define i1 @is_minus_one_32(float noundef %x) {
; CHECK-LABEL: @is_minus_one_32(
; CHECK-NOT: copysign
; CHECK: fcmp olt float %x, 0.000000e+00
  %z = fcmp ueq float %x, 0.0
  %c = call float @llvm.copysign.f32(float 1.0, float %x)
  %s = select i1 %z, float %x, float %c
  %r = fcmp oeq float %s, -1.0
  ret i1 %r
}

define i1 @unordered_32(float noundef %x) {
; CHECK-LABEL: @unordered_32(
; CHECK-NOT: copysign
; CHECK: fcmp ugt float %x, 0.000000e+00
  %z = fcmp ueq float %x, 0.0
  %c = call float @llvm.copysign.f32(float 1.0, float %x)
  %s = select i1 %z, float %x, float %c
  %r = fcmp ugt float %s, 0.0
  ret i1 %r
}

define i1 @is_zero_32(float noundef %x) {
; CHECK-LABEL: @is_zero_32(
; CHECK-NOT: copysign
; CHECK: fcmp oeq float %x, 0.000000e+00
  %z = fcmp ueq float %x, 0.0
  %c = call float @llvm.copysign.f32(float 1.0, float %x)
  %s = select i1 %z, float %x, float %c
  %r = fcmp oeq float %s, 0.0
  ret i1 %r
}

define i1 @not_zero_32(float noundef %x) {
; CHECK-LABEL: @not_zero_32(
; CHECK-NOT: copysign
; CHECK: fcmp one float %x, 0.000000e+00
  %z = fcmp ueq float %x, 0.0
  %c = call float @llvm.copysign.f32(float 1.0, float %x)
  %s = select i1 %z, float %x, float %c
  %r = fcmp one float %s, 0.0
  ret i1 %r
}

define i1 @ge_one_32(float noundef %x) {
; CHECK-LABEL: @ge_one_32(
; CHECK-NOT: copysign
; CHECK: fcmp ogt float %x, 0.000000e+00
  %z = fcmp ueq float %x, 0.0
  %c = call float @llvm.copysign.f32(float 1.0, float %x)
  %s = select i1 %z, float %x, float %c
  %r = fcmp oge float %s, 1.0
  ret i1 %r
}

define i1 @lt_one_32(float noundef %x) {
; CHECK-LABEL: @lt_one_32(
; CHECK-NOT: copysign
; CHECK: fcmp ole float %x, 0.000000e+00
  %z = fcmp ueq float %x, 0.0
  %c = call float @llvm.copysign.f32(float 1.0, float %x)
  %s = select i1 %z, float %x, float %c
  %r = fcmp olt float %s, 1.0
  ret i1 %r
}

define i1 @ne_one_unordered_64(double noundef %x) {
; CHECK-LABEL: @ne_one_unordered_64(
; CHECK-NOT: copysign
; CHECK: fcmp ule double %x, 0.000000e+00
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp une double %s, 1.0
  ret i1 %r
}

define i1 @gt_minus_one_64(double noundef %x) {
; CHECK-LABEL: @gt_minus_one_64(
; CHECK-NOT: copysign
; CHECK: fcmp oge double %x, 0.000000e+00
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp ogt double %s, -1.0
  ret i1 %r
}

; No non-NaN signum result equals one half.
define i1 @vs_half_32(float noundef %x) {
; CHECK-LABEL: @vs_half_32(
; CHECK-NOT: copysign
; CHECK: ret i1 false
  %z = fcmp ueq float %x, 0.0
  %c = call float @llvm.copysign.f32(float 1.0, float %x)
  %s = select i1 %z, float %x, float %c
  %r = fcmp oeq float %s, 0.5
  ret i1 %r
}

; Degenerate comparisons preserve orderedness and unorderedness.
define i1 @ge_minus_one_64(double noundef %x) {
; CHECK-LABEL: @ge_minus_one_64(
; CHECK-NOT: copysign
; CHECK: fcmp ord double %x, 0.000000e+00
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp oge double %s, -1.0
  ret i1 %r
}

define i1 @lt_minus_one_64(double noundef %x) {
; CHECK-LABEL: @lt_minus_one_64(
; CHECK-NOT: copysign
; CHECK: ret i1 false
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp olt double %s, -1.0
  ret i1 %r
}

define i1 @ult_minus_one_64(double noundef %x) {
; CHECK-LABEL: @ult_minus_one_64(
; CHECK-NOT: copysign
; CHECK: fcmp uno double %x, 0.000000e+00
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp ult double %s, -1.0
  ret i1 %r
}

define i1 @eq_minus_one_32(float noundef %x) {
; CHECK-LABEL: @eq_minus_one_32(
; CHECK-NOT: copysign
; CHECK: fcmp olt float %x, 0.000000e+00
  %z = fcmp ueq float %x, 0.0
  %c = call float @llvm.copysign.f32(float 1.0, float %x)
  %s = select i1 %z, float %x, float %c
  %r = fcmp oeq float %s, -1.0
  ret i1 %r
}

; No signum result is ordered and greater than two.
define i1 @gt_two_32(float noundef %x) {
; CHECK-LABEL: @gt_two_32(
; CHECK-NOT: copysign
; CHECK: ret i1 false
  %z = fcmp ueq float %x, 0.0
  %c = call float @llvm.copysign.f32(float 1.0, float %x)
  %s = select i1 %z, float %x, float %c
  %r = fcmp ogt float %s, 2.0
  ret i1 %r
}

define float @idempotent_32(float noundef %x) {
; CHECK-LABEL: @idempotent_32(
; CHECK: %c = call float @llvm.copysign.f32
; CHECK-NOT: copysign
; CHECK: ret float %s
  %z = fcmp ueq float %x, 0.0
  %c = call float @llvm.copysign.f32(float 1.0, float %x)
  %s = select i1 %z, float %x, float %c
  %zz = fcmp ueq float %s, 0.0
  %cc = call float @llvm.copysign.f32(float 1.0, float %s)
  %ss = select i1 %zz, float %s, float %cc
  ret float %ss
}
define float @mixed_users_32(float noundef %x, ptr %out) {
; CHECK-LABEL: @mixed_users_32(
; CHECK: call float @llvm.copysign.f32
; CHECK: %[[R:.*]] = fcmp ogt float %x, 0.000000e+00
; CHECK: store i1 %[[R]]
; CHECK: ret float %s
  %z = fcmp ueq float %x, 0.0
  %c = call float @llvm.copysign.f32(float 1.0, float %x)
  %s = select i1 %z, float %x, float %c
  %r = fcmp oeq float %s, 1.0
  store i1 %r, ptr %out
  ret float %s
}

define i1 @positive_64(double noundef %x) {
; CHECK-LABEL: @positive_64(
; CHECK-NOT: copysign
; CHECK: fcmp ogt double %x, 0.000000e+00
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp ogt double %s, 0.0
  ret i1 %r
}

define i1 @negative_64(double noundef %x) {
; CHECK-LABEL: @negative_64(
; CHECK-NOT: copysign
; CHECK: fcmp olt double %x, 0.000000e+00
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp olt double %s, 0.0
  ret i1 %r
}

define i1 @is_one_64(double noundef %x) {
; CHECK-LABEL: @is_one_64(
; CHECK-NOT: copysign
; CHECK: fcmp ogt double %x, 0.000000e+00
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp oeq double %s, 1.0
  ret i1 %r
}

define i1 @is_minus_one_64(double noundef %x) {
; CHECK-LABEL: @is_minus_one_64(
; CHECK-NOT: copysign
; CHECK: fcmp olt double %x, 0.000000e+00
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp oeq double %s, -1.0
  ret i1 %r
}

define i1 @unordered_64(double noundef %x) {
; CHECK-LABEL: @unordered_64(
; CHECK-NOT: copysign
; CHECK: fcmp ugt double %x, 0.000000e+00
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp ugt double %s, 0.0
  ret i1 %r
}

define double @idempotent_64(double noundef %x) {
; CHECK-LABEL: @idempotent_64(
; CHECK: %c = call double @llvm.copysign.f64
; CHECK-NOT: copysign
; CHECK: ret double %s
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %zz = fcmp ueq double %s, 0.0
  %cc = call double @llvm.copysign.f64(double 1.0, double %s)
  %ss = select i1 %zz, double %s, double %cc
  ret double %ss
}
define double @mixed_users_64(double noundef %x, ptr %out) {
; CHECK-LABEL: @mixed_users_64(
; CHECK: call double @llvm.copysign.f64
; CHECK: %[[R:.*]] = fcmp ogt double %x, 0.000000e+00
; CHECK: store i1 %[[R]]
; CHECK: ret double %s
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp oeq double %s, 1.0
  store i1 %r, ptr %out
  ret double %s
}

define i1 @unstable_signum(double %x) {
; CHECK-LABEL: @unstable_signum(
; CHECK: call double @llvm.copysign.f64
; CHECK: fcmp ogt double %s, 0.000000e+00
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp ogt double %s, 0.0
  ret i1 %r
}
define i1 @frozen_signum(double %v) {
; CHECK-LABEL: @frozen_signum(
; CHECK: %x = freeze double %v
; CHECK-NOT: copysign
; CHECK: fcmp ogt double %x, 0.000000e+00
  %x = freeze double %v
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %r = fcmp ogt double %s, 0.0
  ret i1 %r
}

define double @merged_signum(double noundef %x) {
; CHECK-LABEL: @merged_signum(
; CHECK: %c = call double @llvm.copysign.f64
; CHECK-NOT: copysign
; CHECK: ret double %s
  %z = fcmp ueq double %x, 0.0
  %c = call double @llvm.copysign.f64(double 1.0, double %x)
  %s = select i1 %z, double %x, double %c
  %cc = call double @llvm.copysign.f64(double 1.0, double %s)
  %ss = select i1 %z, double %x, double %cc
  ret double %ss
}
