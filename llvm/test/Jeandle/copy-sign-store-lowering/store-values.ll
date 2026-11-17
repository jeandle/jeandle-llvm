; RUN: opt -passes=copy-sign-store-lowering -mtriple=x86_64-unknown-linux-gnu -verify-each -S < %s | FileCheck %s
; RUN: opt -passes=copy-sign-store-lowering -mtriple=i386-unknown-linux-gnu -verify-each -S < %s | FileCheck %s

declare float @llvm.copysign.f32(float, float)
declare double @llvm.copysign.f64(double, double)
declare void @poll()

; Loads can feed either register bank, so both operands stay GPR-resident.
define void @store_f32(ptr %mp, ptr %sp, ptr %p) {
; CHECK-LABEL: @store_f32(
; CHECK: %[[M:.*]] = bitcast float {{.*}} to i32
; CHECK-NEXT: %[[S:.*]] = bitcast float {{.*}} to i32
; CHECK-NEXT: %[[MAG:.*]] = and i32 %[[M]], 2147483647
; CHECK-NEXT: %[[SIGN:.*]] = and i32 %[[S]], -2147483648
; CHECK-NEXT: %[[BITS:.*]] = or i32 %[[MAG]], %[[SIGN]]
; CHECK-NEXT: %[[VALUE:.*]] = bitcast i32 %[[BITS]] to float
; CHECK-NEXT: store float %[[VALUE]], ptr %p, align 4
; CHECK-NEXT: ret void
  %m = load float, ptr %mp, align 4
  %s = load float, ptr %sp, align 4
  %r = call float @llvm.copysign.f32(float %m, float %s)
  store float %r, ptr %p, align 4
  ret void
}

define void @store_f64(ptr %mp, ptr %sp, ptr addrspace(1) %p) {
; CHECK-LABEL: @store_f64(
; CHECK: %[[M:.*]] = bitcast double {{.*}} to i64
; CHECK-NEXT: %[[S:.*]] = bitcast double {{.*}} to i64
; CHECK-NEXT: %[[MAG:.*]] = and i64 %[[M]], 9223372036854775807
; CHECK-NEXT: %[[SIGN:.*]] = and i64 %[[S]], -9223372036854775808
; CHECK-NEXT: %[[BITS:.*]] = or i64 %[[MAG]], %[[SIGN]]
; CHECK-NEXT: %[[VALUE:.*]] = bitcast i64 %[[BITS]] to double
; CHECK-NEXT: store atomic double %[[VALUE]], ptr addrspace(1) %p unordered, align 8
; CHECK-NEXT: ret void
  %m = load double, ptr %mp, align 8
  %s = load double, ptr %sp, align 8
  %r = call double @llvm.copysign.f64(double %m, double %s)
  store atomic double %r, ptr addrspace(1) %p unordered, align 8
  ret void
}

; FP-computed operands live in XMM; O3 canonicalizes the integer pattern
; back to llvm.copysign for them, so they are not rewritten.
define void @fp_params_not_lowered(float %m, float %s, ptr %p) {
; CHECK-LABEL: @fp_params_not_lowered(
; CHECK: %[[R:.*]] = call float @llvm.copysign.f32(float %m, float %s)
; CHECK-NEXT: store float %[[R]], ptr %p, align 4
; CHECK-NEXT: ret void
  %r = call float @llvm.copysign.f32(float %m, float %s)
  store float %r, ptr %p, align 4
  ret void
}

; One FP-computed operand still crosses banks; leave the intrinsic alone.
define void @mixed_params_not_lowered(float %m, ptr %sp, ptr %p) {
; CHECK-LABEL: @mixed_params_not_lowered(
; CHECK: %[[S:.*]] = load float, ptr %sp
; CHECK-NEXT: %[[R:.*]] = call float @llvm.copysign.f32(float %m, float %[[S]])
; CHECK-NEXT: store float %[[R]], ptr %p, align 4
; CHECK-NEXT: ret void
  %s = load float, ptr %sp, align 4
  %r = call float @llvm.copysign.f32(float %m, float %s)
  store float %r, ptr %p, align 4
  ret void
}

define void @two_stores(ptr %mp, ptr %sp, ptr %p, ptr %q) {
; CHECK-LABEL: @two_stores(
; CHECK: %[[BITS:.*]] = or i64
; CHECK-NEXT: %[[VALUE:.*]] = bitcast i64 %[[BITS]] to double
; CHECK-NEXT: store double %[[VALUE]], ptr %p, align 8
; CHECK-NEXT: store volatile double %[[VALUE]], ptr %q, align 8
; CHECK-NEXT: ret void
  %m = load double, ptr %mp, align 8
  %s = load double, ptr %sp, align 8
  %r = call double @llvm.copysign.f64(double %m, double %s)
  store double %r, ptr %p, align 8
  store volatile double %r, ptr %q, align 8
  ret void
}

define double @aliasing_load(ptr %mp, ptr %sp, ptr %p, ptr %q) {
; CHECK-LABEL: @aliasing_load(
; CHECK: %[[VALUE:.*]] = bitcast i64 {{.*}} to double
; CHECK-NEXT: store double %[[VALUE]], ptr %p, align 8
; CHECK-NEXT: %v = load double, ptr %q, align 8
; CHECK-NEXT: ret double %v
  %m = load double, ptr %mp, align 8
  %s = load double, ptr %sp, align 8
  %r = call double @llvm.copysign.f64(double %m, double %s)
  store double %r, ptr %p, align 8
  %v = load double, ptr %q, align 8
  ret double %v
}

define void @ordered_volatile(ptr %mp, ptr %sp, ptr %p) {
; CHECK-LABEL: @ordered_volatile(
; CHECK: %[[VALUE:.*]] = bitcast i32 {{.*}} to float
; CHECK-NEXT: store atomic volatile float %[[VALUE]], ptr %p syncscope("singlethread") seq_cst, align 4, !annotation ![[NOTE:[0-9]+]]
; CHECK-NEXT: ret void
  %m = load float, ptr %mp, align 4
  %s = load float, ptr %sp, align 4
  %r = call float @llvm.copysign.f32(float %m, float %s)
  store atomic volatile float %r, ptr %p syncscope("singlethread") seq_cst, align 4, !annotation !1
  ret void
}

define void @loop_store(ptr %mp, ptr %sp, ptr %p, i64 %n) {
; CHECK-LABEL: @loop_store(
; CHECK: entry:
; CHECK-NEXT: br label %loop
; CHECK: loop:
; CHECK-NEXT: %i = phi i64 [ 0, %entry ], [ %next, %loop ]
; CHECK: %[[VALUE:.*]] = bitcast i64 {{.*}} to double
; CHECK-NEXT: %address = getelementptr double, ptr %p, i64 %i
; CHECK-NEXT: store atomic double %[[VALUE]], ptr %address unordered, align 8
; CHECK-NEXT: call void @poll()
; CHECK-NEXT: %next = add i64 %i, 1
; CHECK-NEXT: %done = icmp eq i64 %next, %n
; CHECK-NEXT: br i1 %done, label %exit, label %loop
; CHECK: exit:
; CHECK-NEXT: ret void
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %m = load double, ptr %mp, align 8
  %s = load double, ptr %sp, align 8
  %r = call double @llvm.copysign.f64(double %m, double %s)
  %address = getelementptr double, ptr %p, i64 %i
  store atomic double %r, ptr %address unordered, align 8
  call void @poll()
  %next = add i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

; CHECK: ![[NOTE]] = !{!"copySign output"}
!java-method-compilation = !{!0}
!0 = !{}
!1 = !{!"copySign output"}
