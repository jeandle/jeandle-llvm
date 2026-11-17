; RUN: opt -S -verify-each -passes='numeric-intrinsic-folding,instcombine' %s | FileCheck %s
; RUN: opt -S -verify-each -passes='numeric-intrinsic-folding,numeric-intrinsic-folding,instcombine' %s | FileCheck %s

!java-method-compilation = !{}
declare i32 @jeandle.round.float(float) memory(none) nounwind willreturn "lower-phase"="1"
declare i64 @jeandle.round.double(double) memory(none) nounwind willreturn "lower-phase"="1"

define i32 @wide_signed(i64 %x) {
; CHECK-LABEL: @wide_signed(
; CHECK: %f = sitofp i64 %x to float
; CHECK-NEXT: [[R:%.*]] = call i32 @llvm.fptosi.sat.i32.f32(float %f)
; CHECK-NEXT: ret i32 [[R]]
  %f = sitofp i64 %x to float
  %r = call i32 @jeandle.round.float(float %f)
  ret i32 %r
}

define i64 @wide_unsigned(i64 %x) {
; CHECK-LABEL: @wide_unsigned(
; CHECK: %f = uitofp i64 %x to double
; CHECK-NEXT: [[R:%.*]] = call i64 @llvm.fptosi.sat.i64.f64(double %f)
; CHECK-NEXT: ret i64 [[R]]
  %f = uitofp i64 %x to double
  %r = call i64 @jeandle.round.double(double %f)
  ret i64 %r
}

define i32 @integer_overflow_to_infinity(i128 %x) {
; CHECK-LABEL: @integer_overflow_to_infinity(
; CHECK: %f = uitofp i128 %x to float
; CHECK-NEXT: [[R:%.*]] = call i32 @llvm.fptosi.sat.i32.f32(float %f)
; CHECK-NEXT: ret i32 [[R]]
  %f = uitofp i128 %x to float
  %r = call i32 @jeandle.round.float(float %f)
  ret i32 %r
}

define i32 @shared_cast(i32 %x, ptr %out) {
; CHECK-LABEL: @shared_cast(
; CHECK: %f = sitofp i32 %x to float
; CHECK-NEXT: store float %f, ptr %out
; CHECK-NEXT: [[R:%.*]] = call i32 @llvm.fptosi.sat.i32.f32(float %f)
; CHECK-NEXT: ret i32 [[R]]
  %f = sitofp i32 %x to float
  store float %f, ptr %out
  %r = call i32 @jeandle.round.float(float %f)
  ret i32 %r
}

define i64 @frozen_source(i64 %x) {
; CHECK-LABEL: @frozen_source(
; CHECK: %stable = freeze i64 %x
; CHECK-NEXT: %f = sitofp i64 %stable to double
; CHECK-NEXT: [[R:%.*]] = call i64 @llvm.fptosi.sat.i64.f64(double %f)
; CHECK-NEXT: ret i64 [[R]]
  %stable = freeze i64 %x
  %f = sitofp i64 %stable to double
  %r = call i64 @jeandle.round.double(double %f)
  ret i64 %r
}

define i64 @loop_phi(i64 %x, i64 %count) {
; CHECK-LABEL: @loop_phi(
; CHECK: %value = phi i64
; CHECK: %f = sitofp i64 %value to double
; CHECK-NEXT: [[R:%.*]] = call i64 @llvm.fptosi.sat.i64.f64(double %f)
; CHECK: ret i64 [[R]]
entry:
  br label %loop
loop:
  %value = phi i64 [ %x, %entry ], [ %next, %loop ]
  %index = phi i64 [ 0, %entry ], [ %increment, %loop ]
  %f = sitofp i64 %value to double
  %r = call i64 @jeandle.round.double(double %f)
  %next = add i64 %r, 1
  %increment = add i64 %index, 1
  %more = icmp ult i64 %increment, %count
  br i1 %more, label %loop, label %exit
exit:
  ret i64 %r
}

define i32 @floating_input(float %x) {
; CHECK-LABEL: @floating_input(
; CHECK: %r = call i32 @jeandle.round.float(float %x)
  %r = call i32 @jeandle.round.float(float %x)
  ret i32 %r
}

define i64 @floating_extension(float %x) {
; CHECK-LABEL: @floating_extension(
; CHECK: %f = fpext float %x to double
; CHECK-NEXT: %r = call i64 @jeandle.round.double(double %f)
  %f = fpext float %x to double
  %r = call i64 @jeandle.round.double(double %f)
  ret i64 %r
}

define i32 @bundled_lossy(i32 %x) {
; CHECK-LABEL: @bundled_lossy(
; CHECK: call i32 @jeandle.round.float(float %f) [ "deopt"(i32 %x) ]
  %f = sitofp i32 %x to float
  %r = call i32 @jeandle.round.float(float %f) [ "deopt"(i32 %x) ]
  ret i32 %r
}
