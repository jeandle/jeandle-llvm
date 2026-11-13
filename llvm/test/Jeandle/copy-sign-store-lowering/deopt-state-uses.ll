; RUN: opt -passes=copy-sign-store-lowering -mtriple=x86_64-unknown-linux-gnu -verify-each -S < %s | FileCheck %s

declare float @llvm.copysign.f32(float, float)
declare double @llvm.copysign.f64(double, double)
declare void @llvm.experimental.deoptimize.isVoid(...)
declare void @safepoint()
declare void @observe(double)

define void @store_and_deopt_f64(double %m, double %s, ptr %p, i1 %failed) {
; CHECK-LABEL: @store_and_deopt_f64(
; CHECK: %[[BITS:.*]] = or i64
; CHECK-NEXT: %[[VALUE:.*]] = bitcast i64 %[[BITS]] to double
; CHECK-NEXT: br i1 %failed, label %deopt, label %store
; CHECK: deopt:
; CHECK-NEXT: call void (...) @llvm.experimental.deoptimize.isVoid() [ "deopt"(i32 19, double %[[VALUE]]) ]
; CHECK-NEXT: ret void
; CHECK: store:
; CHECK-NEXT: store atomic double %[[VALUE]], ptr %p unordered, align 8
; CHECK-NEXT: ret void
  %r = call double @llvm.copysign.f64(double %m, double %s)
  br i1 %failed, label %deopt, label %store
deopt:
  call void (...) @llvm.experimental.deoptimize.isVoid() [ "deopt"(i32 19, double %r) ]
  ret void
store:
  store atomic double %r, ptr %p unordered, align 8
  ret void
}

define void @store_and_deopt_f32(float %m, float %s, ptr %p) {
; CHECK-LABEL: @store_and_deopt_f32(
; CHECK: %[[BITS:.*]] = or i32
; CHECK-NEXT: %[[VALUE:.*]] = bitcast i32 %[[BITS]] to float
; CHECK-NEXT: call void @safepoint() [ "deopt"(float %[[VALUE]], float %[[VALUE]]) ]
; CHECK-NEXT: store volatile float %[[VALUE]], ptr %p, align 4
; CHECK-NEXT: ret void
  %r = call float @llvm.copysign.f32(float %m, float %s)
  call void @safepoint() [ "deopt"(float %r, float %r) ]
  store volatile float %r, ptr %p, align 4
  ret void
}

define void @deopt_only(double %m, double %s) {
; CHECK-LABEL: @deopt_only(
; CHECK-NEXT: %r = call double @llvm.copysign.f64(double %m, double %s)
; CHECK-NEXT: call void @safepoint() [ "deopt"(double %r) ]
; CHECK-NEXT: ret void
  %r = call double @llvm.copysign.f64(double %m, double %s)
  call void @safepoint() [ "deopt"(double %r) ]
  ret void
}

define void @store_and_call_argument(double %m, double %s, ptr %p) {
; CHECK-LABEL: @store_and_call_argument(
; CHECK-NEXT: %r = call double @llvm.copysign.f64(double %m, double %s)
; CHECK-NEXT: call void @observe(double %r) [ "deopt"(double %r) ]
; CHECK-NEXT: store double %r, ptr %p, align 8
; CHECK-NEXT: ret void
  %r = call double @llvm.copysign.f64(double %m, double %s)
  call void @observe(double %r) [ "deopt"(double %r) ]
  store double %r, ptr %p, align 8
  ret void
}

define void @store_and_other_bundle(double %m, double %s, ptr %p) {
; CHECK-LABEL: @store_and_other_bundle(
; CHECK-NEXT: %r = call double @llvm.copysign.f64(double %m, double %s)
; CHECK-NEXT: call void @safepoint() [ "deopt"(double %r), "other"(double %r) ]
; CHECK-NEXT: store double %r, ptr %p, align 8
; CHECK-NEXT: ret void
  %r = call double @llvm.copysign.f64(double %m, double %s)
  call void @safepoint() [ "deopt"(double %r), "other"(double %r) ]
  store double %r, ptr %p, align 8
  ret void
}

define i64 @store_and_deopt_and_reduce(double %m, double %s, ptr %p, i64 %acc) {
; CHECK-LABEL: @store_and_deopt_and_reduce(
; CHECK-NEXT: %r = call double @llvm.copysign.f64(double %m, double %s)
; CHECK-NEXT: call void @safepoint() [ "deopt"(double %r) ]
; CHECK-NEXT: store double %r, ptr %p, align 8
; CHECK-NEXT: %bits = bitcast double %r to i64
; CHECK-NEXT: %sum = add i64 %acc, %bits
; CHECK-NEXT: ret i64 %sum
  %r = call double @llvm.copysign.f64(double %m, double %s)
  call void @safepoint() [ "deopt"(double %r) ]
  store double %r, ptr %p, align 8
  %bits = bitcast double %r to i64
  %sum = add i64 %acc, %bits
  ret i64 %sum
}

!java-method-compilation = !{!0}
!0 = !{}
