; RUN: opt -S -verify-each -passes='numeric-intrinsic-folding,instcombine' %s | FileCheck %s
; RUN: opt -S -verify-each -passes='numeric-intrinsic-folding,numeric-intrinsic-folding,instcombine' %s | FileCheck %s
!java-method-compilation = !{}
declare i64 @jeandle.round.double(double) memory(none) nounwind willreturn "lower-phase"="1"
declare i32 @jeandle.round.float(float) memory(none) nounwind willreturn "lower-phase"="1"

define i32 @signed_float_shift(i32 %x) {
; CHECK-LABEL: @signed_float_shift(
; CHECK-NOT: sitofp
; CHECK-NOT: uitofp
; CHECK-NOT: call
; CHECK: ret i32 %v
  %v = shl i32 %x, 8
  %f = sitofp i32 %v to float
  %r = call i32 @jeandle.round.float(float %f)
  ret i32 %r
}

define i32 @signed_float_mask(i32 %x) {
; CHECK-LABEL: @signed_float_mask(
; CHECK-NOT: sitofp
; CHECK-NOT: uitofp
; CHECK-NOT: call
; CHECK: ret i32 %v
  %v = and i32 %x, -128
  %f = sitofp i32 %v to float
  %r = call i32 @jeandle.round.float(float %f)
  ret i32 %r
}

define i64 @signed_double_mask(i64 %x) {
; CHECK-LABEL: @signed_double_mask(
; CHECK-NOT: sitofp
; CHECK-NOT: uitofp
; CHECK-NOT: call
; CHECK: ret i64 %v
  %v = and i64 %x, -1024
  %f = sitofp i64 %v to double
  %r = call i64 @jeandle.round.double(double %f)
  ret i64 %r
}

define i64 @unsigned_double_mask(i64 %x) {
; CHECK-LABEL: @unsigned_double_mask(
; CHECK-NOT: sitofp
; CHECK-NOT: uitofp
; CHECK-NOT: call
; CHECK: ret i64 %v
  %v = and i64 %x, 9223372036854774784
  %f = uitofp i64 %v to double
  %r = call i64 @jeandle.round.double(double %f)
  ret i64 %r
}

define i32 @lossy_float(i32 %x) {
; CHECK-LABEL: @lossy_float(
; CHECK: %f = {{[su]}}itofp
; CHECK-NEXT: [[R:%.*]] = call i32 @llvm.fptosi.sat.i32.f32(float %f)
; CHECK-NEXT: ret i32 [[R]]
  %v = shl i32 %x, 6
  %f = sitofp i32 %v to float
  %r = call i32 @jeandle.round.float(float %f)
  ret i32 %r
}

define i64 @lossy_double(i64 %x) {
; CHECK-LABEL: @lossy_double(
; CHECK: %f = {{[su]}}itofp
; CHECK-NEXT: [[R:%.*]] = call i64 @llvm.fptosi.sat.i64.f64(double %f)
; CHECK-NEXT: ret i64 [[R]]
  %v = shl i64 %x, 9
  %f = sitofp i64 %v to double
  %r = call i64 @jeandle.round.double(double %f)
  ret i64 %r
}

define i32 @unsigned_float_saturation(i32 %x) {
; CHECK-LABEL: @unsigned_float_saturation(
; CHECK: %f = {{[su]}}itofp
; CHECK-NEXT: [[R:%.*]] = call i32 @llvm.fptosi.sat.i32.f32(float %f)
; CHECK-NEXT: ret i32 [[R]]
  %v = shl i32 %x, 8
  %f = uitofp i32 %v to float
  %r = call i32 @jeandle.round.float(float %f)
  ret i32 %r
}

define i64 @unsigned_double_saturation(i64 %x) {
; CHECK-LABEL: @unsigned_double_saturation(
; CHECK: %f = {{[su]}}itofp
; CHECK-NEXT: [[R:%.*]] = call i64 @llvm.fptosi.sat.i64.f64(double %f)
; CHECK-NEXT: ret i64 [[R]]
  %v = shl i64 %x, 11
  %f = uitofp i64 %v to double
  %r = call i64 @jeandle.round.double(double %f)
  ret i64 %r
}

define i32 @wide_float_saturation(i64 %x) {
; CHECK-LABEL: @wide_float_saturation(
; CHECK: %f = {{[su]}}itofp
; CHECK-NEXT: [[R:%.*]] = call i32 @llvm.fptosi.sat.i32.f32(float %f)
; CHECK-NEXT: ret i32 [[R]]
  %v = shl i64 %x, 40
  %f = sitofp i64 %v to float
  %r = call i32 @jeandle.round.float(float %f)
  ret i32 %r
}
