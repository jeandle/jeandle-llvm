; RUN: opt -passes='function(copy-sign-store-lowering),default<O3>' -mtriple=x86_64-unknown-linux-gnu -verify-each -S < %s | FileCheck %s
; RUN: opt -passes='default<O3>' -mtriple=x86_64-unknown-linux-gnu -verify-each -S < %s | FileCheck %s --check-prefix=CONTROL

declare float @llvm.copysign.f32(float, float)
declare double @llvm.copysign.f64(double, double)
declare void @safepoint()

; Pure FP arguments can canonicalize back to the intrinsic before store folding.
define void @fp_argument_store_f32(float %m, float %s, ptr %p) {
; CHECK-LABEL: @fp_argument_store_f32(
; CHECK: %[[VALUE:.*]] = {{(tail )?}}call float @llvm.copysign.f32(float %m, float %s)
; CHECK-NEXT: store float %[[VALUE]], ptr %p, align 4
; CHECK-NEXT: ret void
  %r = call float @llvm.copysign.f32(float %m, float %s)
  store float %r, ptr %p, align 4
  ret void
}

define void @fp_argument_store_f64(double %m, double %s, ptr %p) {
; CHECK-LABEL: @fp_argument_store_f64(
; CHECK: %[[VALUE:.*]] = {{(tail )?}}call double @llvm.copysign.f64(double %m, double %s)
; CHECK-NEXT: store atomic double %[[VALUE]], ptr %p unordered, align 8
; CHECK-NEXT: ret void
  %r = call double @llvm.copysign.f64(double %m, double %s)
  store atomic double %r, ptr %p unordered, align 8
  ret void
}

; Primitive Java array loads are unordered atomic FP loads before O3. Exposing
; their bits allows O3 to combine both the loads and the final store to integers.
define void @loaded_store_f32(ptr %mp, ptr %sp, ptr %p) {
; CHECK-LABEL: @loaded_store_f32(
; CHECK: %[[M:.*]] = load atomic i32, ptr %mp unordered, align 4
; CHECK-NEXT: %[[S:.*]] = load atomic i32, ptr %sp unordered, align 4
; CHECK-NEXT: %[[MAG:.*]] = and i32 %[[M]], 2147483647
; CHECK-NEXT: %[[SIGN:.*]] = and i32 %[[S]], -2147483648
; CHECK-NEXT: %[[BITS:.*]] = or{{( disjoint)?}} i32 %[[SIGN]], %[[MAG]]
; CHECK-NEXT: store atomic i32 %[[BITS]], ptr %p unordered, align 4
; CHECK-NEXT: ret void
; CONTROL-LABEL: @loaded_store_f32(
; CONTROL: %m = load atomic float, ptr %mp unordered, align 4
; CONTROL-NEXT: %s = load atomic float, ptr %sp unordered, align 4
; CONTROL-NEXT: %r = {{(tail )?}}call float @llvm.copysign.f32(float %m, float %s)
; CONTROL-NEXT: store atomic float %r, ptr %p unordered, align 4
  %m = load atomic float, ptr %mp unordered, align 4
  %s = load atomic float, ptr %sp unordered, align 4
  %r = call float @llvm.copysign.f32(float %m, float %s)
  store atomic float %r, ptr %p unordered, align 4
  ret void
}

define void @loaded_store_f64(ptr %mp, ptr %sp, ptr %p) {
; CHECK-LABEL: @loaded_store_f64(
; CHECK: %[[M:.*]] = load atomic i64, ptr %mp unordered, align 8
; CHECK-NEXT: %[[S:.*]] = load atomic i64, ptr %sp unordered, align 8
; CHECK-NEXT: %[[MAG:.*]] = and i64 %[[M]], 9223372036854775807
; CHECK-NEXT: %[[SIGN:.*]] = and i64 %[[S]], -9223372036854775808
; CHECK-NEXT: %[[BITS:.*]] = or{{( disjoint)?}} i64 %[[SIGN]], %[[MAG]]
; CHECK-NEXT: store atomic i64 %[[BITS]], ptr %p unordered, align 8
; CHECK-NEXT: ret void
; CONTROL-LABEL: @loaded_store_f64(
; CONTROL: %m = load atomic double, ptr %mp unordered, align 8
; CONTROL-NEXT: %s = load atomic double, ptr %sp unordered, align 8
; CONTROL-NEXT: %r = {{(tail )?}}call double @llvm.copysign.f64(double %m, double %s)
; CONTROL-NEXT: store atomic double %r, ptr %p unordered, align 8
  %m = load atomic double, ptr %mp unordered, align 8
  %s = load atomic double, ptr %sp unordered, align 8
  %r = call double @llvm.copysign.f64(double %m, double %s)
  store atomic double %r, ptr %p unordered, align 8
  ret void
}

define void @loaded_store_deopt_f32(ptr %mp, ptr %sp, ptr %p) {
; CHECK-LABEL: @loaded_store_deopt_f32(
; CHECK: %[[M:.*]] = load atomic i32, ptr %mp unordered, align 4
; CHECK-NEXT: %[[S:.*]] = load atomic i32, ptr %sp unordered, align 4
; CHECK-NEXT: %[[MAG:.*]] = and i32 %[[M]], 2147483647
; CHECK-NEXT: %[[SIGN:.*]] = and i32 %[[S]], -2147483648
; CHECK-NEXT: %[[BITS:.*]] = or{{( disjoint)?}} i32 %[[SIGN]], %[[MAG]]
; CHECK-DAG: %[[VALUE:.*]] = bitcast i32 %[[BITS]] to float
; CHECK-DAG: store atomic i32 %[[BITS]], ptr %p unordered, align 4
; CHECK: call void @safepoint() [ "deopt"(float %[[VALUE]]) ]
; CHECK-NEXT: ret void
; CONTROL-LABEL: @loaded_store_deopt_f32(
; CONTROL: %r = {{(tail )?}}call float @llvm.copysign.f32(float %m, float %s)
; CONTROL-NEXT: store atomic float %r, ptr %p unordered, align 4
; CONTROL-NEXT: call void @safepoint() [ "deopt"(float %r) ]
  %m = load atomic float, ptr %mp unordered, align 4
  %s = load atomic float, ptr %sp unordered, align 4
  %r = call float @llvm.copysign.f32(float %m, float %s)
  store atomic float %r, ptr %p unordered, align 4
  call void @safepoint() [ "deopt"(float %r) ]
  ret void
}

define void @loaded_store_deopt_f64(ptr %mp, ptr %sp, ptr %p) {
; CHECK-LABEL: @loaded_store_deopt_f64(
; CHECK: %[[M:.*]] = load atomic i64, ptr %mp unordered, align 8
; CHECK-NEXT: %[[S:.*]] = load atomic i64, ptr %sp unordered, align 8
; CHECK-NEXT: %[[MAG:.*]] = and i64 %[[M]], 9223372036854775807
; CHECK-NEXT: %[[SIGN:.*]] = and i64 %[[S]], -9223372036854775808
; CHECK-NEXT: %[[BITS:.*]] = or{{( disjoint)?}} i64 %[[SIGN]], %[[MAG]]
; CHECK-DAG: %[[VALUE:.*]] = bitcast i64 %[[BITS]] to double
; CHECK-DAG: store atomic i64 %[[BITS]], ptr %p unordered, align 8
; CHECK: call void @safepoint() [ "deopt"(double %[[VALUE]]) ]
; CHECK-NEXT: ret void
; CONTROL-LABEL: @loaded_store_deopt_f64(
; CONTROL: %r = {{(tail )?}}call double @llvm.copysign.f64(double %m, double %s)
; CONTROL-NEXT: store atomic double %r, ptr %p unordered, align 8
; CONTROL-NEXT: call void @safepoint() [ "deopt"(double %r) ]
  %m = load atomic double, ptr %mp unordered, align 8
  %s = load atomic double, ptr %sp unordered, align 8
  %r = call double @llvm.copysign.f64(double %m, double %s)
  store atomic double %r, ptr %p unordered, align 8
  call void @safepoint() [ "deopt"(double %r) ]
  ret void
}

define i64 @raw_reduce(double %m, double %s, i64 %acc) {
; CHECK-LABEL: @raw_reduce(
; CHECK: %r = {{(tail )?}}call double @llvm.copysign.f64(double %m, double %s)
; CHECK-NEXT: %bits = bitcast double %r to i64
; CHECK-NEXT: %sum = add i64 {{(%bits, %acc|%acc, %bits)}}
; CHECK-NEXT: ret i64 %sum
  %r = call double @llvm.copysign.f64(double %m, double %s)
  %bits = bitcast double %r to i64
  %sum = add i64 %acc, %bits
  ret i64 %sum
}

!java-method-compilation = !{!0}
!0 = !{}
