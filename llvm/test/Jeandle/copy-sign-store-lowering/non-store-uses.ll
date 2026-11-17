; RUN: opt -passes=copy-sign-store-lowering -mtriple=x86_64-unknown-linux-gnu -verify-each -S < %s | FileCheck %s

declare float @llvm.copysign.f32(float, float)
declare double @llvm.copysign.f64(double, double)
declare <2 x float> @llvm.copysign.v2f32(<2 x float>, <2 x float>)
declare half @llvm.copysign.f16(half, half)
declare bfloat @llvm.copysign.bf16(bfloat, bfloat)
declare fp128 @llvm.copysign.f128(fp128, fp128)

define double @return_value(double %m, double %s) {
; CHECK-LABEL: @return_value(
; CHECK-NEXT: %r = call double @llvm.copysign.f64(double %m, double %s)
; CHECK-NEXT: ret double %r
  %r = call double @llvm.copysign.f64(double %m, double %s)
  ret double %r
}

define i64 @raw_bits(double %m, double %s) {
; CHECK-LABEL: @raw_bits(
; CHECK-NEXT: %r = call double @llvm.copysign.f64(double %m, double %s)
; CHECK-NEXT: %bits = bitcast double %r to i64
; CHECK-NEXT: ret i64 %bits
  %r = call double @llvm.copysign.f64(double %m, double %s)
  %bits = bitcast double %r to i64
  ret i64 %bits
}

define float @reduction(float %m, float %s, float %acc) {
; CHECK-LABEL: @reduction(
; CHECK-NEXT: %r = call float @llvm.copysign.f32(float %m, float %s)
; CHECK-NEXT: %sum = fadd float %acc, %r
; CHECK-NEXT: ret float %sum
  %r = call float @llvm.copysign.f32(float %m, float %s)
  %sum = fadd float %acc, %r
  ret float %sum
}

define i64 @store_and_raw_reduce(double %m, double %s, ptr %p, i64 %acc) {
; CHECK-LABEL: @store_and_raw_reduce(
; CHECK-NEXT: %r = call double @llvm.copysign.f64(double %m, double %s)
; CHECK-NEXT: store double %r, ptr %p, align 8
; CHECK-NEXT: %bits = bitcast double %r to i64
; CHECK-NEXT: %sum = add i64 %acc, %bits
; CHECK-NEXT: ret i64 %sum
  %r = call double @llvm.copysign.f64(double %m, double %s)
  store double %r, ptr %p, align 8
  %bits = bitcast double %r to i64
  %sum = add i64 %acc, %bits
  ret i64 %sum
}

define double @store_and_return(double %m, double %s, ptr %p) {
; CHECK-LABEL: @store_and_return(
; CHECK-NEXT: %r = call double @llvm.copysign.f64(double %m, double %s)
; CHECK-NEXT: store double %r, ptr %p, align 8
; CHECK-NEXT: ret double %r
  %r = call double @llvm.copysign.f64(double %m, double %s)
  store double %r, ptr %p, align 8
  ret double %r
}

define void @frozen_result_store(double %m, double %s, ptr %p) {
; CHECK-LABEL: @frozen_result_store(
; CHECK-NEXT: %r = call double @llvm.copysign.f64(double %m, double %s)
; CHECK-NEXT: %stable = freeze double %r
; CHECK-NEXT: store double %stable, ptr %p, align 8
; CHECK-NEXT: ret void
  %r = call double @llvm.copysign.f64(double %m, double %s)
  %stable = freeze double %r
  store double %stable, ptr %p, align 8
  ret void
}

define void @unused(double %m, double %s) {
; CHECK-LABEL: @unused(
; CHECK-NEXT: %r = call double @llvm.copysign.f64(double %m, double %s)
; CHECK-NEXT: ret void
  %r = call double @llvm.copysign.f64(double %m, double %s)
  ret void
}

define void @vector_store(<2 x float> %m, <2 x float> %s, ptr %p) {
; CHECK-LABEL: @vector_store(
; CHECK-NEXT: %r = call <2 x float> @llvm.copysign.v2f32(<2 x float> %m, <2 x float> %s)
; CHECK-NEXT: store <2 x float> %r, ptr %p, align 8
  %r = call <2 x float> @llvm.copysign.v2f32(<2 x float> %m, <2 x float> %s)
  store <2 x float> %r, ptr %p, align 8
  ret void
}

define void @half_store(half %m, half %s, ptr %p) {
; CHECK-LABEL: @half_store(
; CHECK-NEXT: %r = call half @llvm.copysign.f16(half %m, half %s)
; CHECK-NEXT: store half %r, ptr %p, align 2
  %r = call half @llvm.copysign.f16(half %m, half %s)
  store half %r, ptr %p, align 2
  ret void
}

define void @bfloat_store(bfloat %m, bfloat %s, ptr %p) {
; CHECK-LABEL: @bfloat_store(
; CHECK-NEXT: %r = call bfloat @llvm.copysign.bf16(bfloat %m, bfloat %s)
; CHECK-NEXT: store bfloat %r, ptr %p, align 2
  %r = call bfloat @llvm.copysign.bf16(bfloat %m, bfloat %s)
  store bfloat %r, ptr %p, align 2
  ret void
}

define void @quad_store(fp128 %m, fp128 %s, ptr %p) {
; CHECK-LABEL: @quad_store(
; CHECK-NEXT: %r = call fp128 @llvm.copysign.f128(fp128 %m, fp128 %s)
; CHECK-NEXT: store fp128 %r, ptr %p, align 16
  %r = call fp128 @llvm.copysign.f128(fp128 %m, fp128 %s)
  store fp128 %r, ptr %p, align 16
  ret void
}

define void @bundled_store(double %m, double %s, ptr %p) {
; CHECK-LABEL: @bundled_store(
; CHECK-NEXT: %r = call double @llvm.copysign.f64(double %m, double %s) [ "deopt"(i32 1) ]
; CHECK-NEXT: store double %r, ptr %p, align 8
  %r = call double @llvm.copysign.f64(double %m, double %s) [ "deopt"(i32 1) ]
  store double %r, ptr %p, align 8
  ret void
}

define double @musttail_call(double %m, double %s) {
; CHECK-LABEL: @musttail_call(
; CHECK-NEXT: %r = musttail call double @llvm.copysign.f64(double %m, double %s)
; CHECK-NEXT: ret double %r
  %r = musttail call double @llvm.copysign.f64(double %m, double %s)
  ret double %r
}

!java-method-compilation = !{!0}
!0 = !{}
