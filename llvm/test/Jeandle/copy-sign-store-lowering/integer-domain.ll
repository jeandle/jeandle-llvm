; RUN: opt -S -verify-each -mtriple=x86_64 -passes='copy-sign-store-lowering,instcombine' %s | FileCheck %s
!java-method-compilation = !{}
declare float @llvm.copysign.f32(float, float)

define i32 @registers_32(i32 %m, i32 %s) {
; CHECK-LABEL: @registers_32(
; CHECK-NOT: call float @llvm.copysign.f32
; CHECK: or{{( disjoint)?}} i32
; CHECK: ret i32

  %mf = bitcast i32 %m to float
  %sf = bitcast i32 %s to float
  %r = call float @llvm.copysign.f32(float %mf, float %sf)
  %bits = bitcast float %r to i32
  ret i32 %bits
}

define i32 @integer_chain_32(i32 %acc, i32 %x, ptr %p, ptr %q) {
; CHECK-LABEL: @integer_chain_32(
; CHECK-NOT: call float @llvm.copysign.f32
; CHECK: or{{( disjoint)?}} i32
; CHECK: ret i32
  %m = add i32 %acc, %x
  %s = load i32, ptr %p
  %mf = bitcast i32 %m to float
  %sf = bitcast i32 %s to float
  %r = call float @llvm.copysign.f32(float %mf, float %sf)
  %bits = bitcast float %r to i32
  ret i32 %bits
}

define i32 @loads_32(i32 %acc, i32 %x, ptr %p, ptr %q) {
; CHECK-LABEL: @loads_32(
; CHECK: call float @llvm.copysign.f32
; CHECK: ret i32
  %m = load i32, ptr %p
  %s = load i32, ptr %q
  %mf = bitcast i32 %m to float
  %sf = bitcast i32 %s to float
  %r = call float @llvm.copysign.f32(float %mf, float %sf)
  %bits = bitcast float %r to i32
  ret i32 %bits
}

define float @fp_sink_32(i32 %m, i32 %s) {
; CHECK-LABEL: @fp_sink_32(
; CHECK: call float @llvm.copysign.f32
  %mf = bitcast i32 %m to float
  %sf = bitcast i32 %s to float
  %r = call float @llvm.copysign.f32(float %mf, float %sf)
  ret float %r
}
declare double @llvm.copysign.f64(double, double)

define i64 @registers_64(i64 %m, i64 %s) {
; CHECK-LABEL: @registers_64(
; CHECK-NOT: call double @llvm.copysign.f64
; CHECK: or{{( disjoint)?}} i64
; CHECK: ret i64

  %mf = bitcast i64 %m to double
  %sf = bitcast i64 %s to double
  %r = call double @llvm.copysign.f64(double %mf, double %sf)
  %bits = bitcast double %r to i64
  ret i64 %bits
}

define i64 @integer_chain_64(i64 %acc, i64 %x, ptr %p, ptr %q) {
; CHECK-LABEL: @integer_chain_64(
; CHECK-NOT: call double @llvm.copysign.f64
; CHECK: or{{( disjoint)?}} i64
; CHECK: ret i64
  %m = add i64 %acc, %x
  %s = load i64, ptr %p
  %mf = bitcast i64 %m to double
  %sf = bitcast i64 %s to double
  %r = call double @llvm.copysign.f64(double %mf, double %sf)
  %bits = bitcast double %r to i64
  ret i64 %bits
}

define i64 @loads_64(i64 %acc, i64 %x, ptr %p, ptr %q) {
; CHECK-LABEL: @loads_64(
; CHECK: call double @llvm.copysign.f64
; CHECK: ret i64
  %m = load i64, ptr %p
  %s = load i64, ptr %q
  %mf = bitcast i64 %m to double
  %sf = bitcast i64 %s to double
  %r = call double @llvm.copysign.f64(double %mf, double %sf)
  %bits = bitcast double %r to i64
  ret i64 %bits
}

define double @fp_sink_64(i64 %m, i64 %s) {
; CHECK-LABEL: @fp_sink_64(
; CHECK: call double @llvm.copysign.f64
  %mf = bitcast i64 %m to double
  %sf = bitcast i64 %s to double
  %r = call double @llvm.copysign.f64(double %mf, double %sf)
  ret double %r
}

declare void @poll()
define i64 @mixed_integer_state(i64 %m, i64 %s, ptr %out) {
; CHECK-LABEL: @mixed_integer_state(
; CHECK-NOT: call double @llvm.copysign.f64
; CHECK: %[[R:.*]] = or{{( disjoint)?}} i64
; CHECK: %[[FP:.*]] = bitcast i64 %[[R]] to double
; CHECK: store i64 %[[R]], ptr %out
; CHECK: call void @poll() [ "deopt"(double %[[FP]]) ]
; CHECK: ret i64 %[[R]]
  %mf = bitcast i64 %m to double
  %sf = bitcast i64 %s to double
  %r = call double @llvm.copysign.f64(double %mf, double %sf)
  store double %r, ptr %out
  call void @poll() [ "deopt"(double %r) ]
  %bits = bitcast double %r to i64
  ret i64 %bits
}

define i32 @folded_sign_load_32(i32 %acc, i32 %x, ptr %p) {
; CHECK-LABEL: @folded_sign_load_32(
; CHECK-NOT: call float @llvm.copysign.f32
; CHECK: or{{( disjoint)?}} i32
; CHECK: ret i32
  %m = add i32 %acc, %x
  %mf = bitcast i32 %m to float
  %sf = load float, ptr %p
  %r = call float @llvm.copysign.f32(float %mf, float %sf)
  %bits = bitcast float %r to i32
  ret i32 %bits
}

define i64 @folded_sign_load_64(i64 %acc, i64 %x, ptr %p) {
; CHECK-LABEL: @folded_sign_load_64(
; CHECK-NOT: call double @llvm.copysign.f64
; CHECK: or{{( disjoint)?}} i64
; CHECK: ret i64
  %m = add i64 %acc, %x
  %mf = bitcast i64 %m to double
  %sf = load double, ptr %p
  %r = call double @llvm.copysign.f64(double %mf, double %sf)
  %bits = bitcast double %r to i64
  ret i64 %bits
}
