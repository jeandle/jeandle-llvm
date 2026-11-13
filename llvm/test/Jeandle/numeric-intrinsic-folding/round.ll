; RUN: opt -S -verify-each -passes='numeric-intrinsic-folding,instcombine' %s | FileCheck %s
; RUN: opt -S -verify-each -passes='numeric-intrinsic-folding,numeric-intrinsic-folding,instcombine' %s | FileCheck %s
!java-method-compilation = !{}
declare i64 @jeandle.round.double(double) memory(none) nounwind willreturn "lower-phase"="1"
declare i32 @jeandle.round.float(float) memory(none) nounwind willreturn "lower-phase"="1"

define i64 @signed_int(i32 %x) {
; CHECK-LABEL: @signed_int(
; CHECK-NOT: call
; CHECK: sext i32 %x to i64
  %f = sitofp i32 %x to double
  %r = call i64 @jeandle.round.double(double %f)
  ret i64 %r
}

define i64 @unsigned_int(i32 %x) {
; CHECK-LABEL: @unsigned_int(
; CHECK-NOT: call
; CHECK: zext i32 %x to i64
  %f = uitofp i32 %x to double
  %r = call i64 @jeandle.round.double(double %f)
  ret i64 %r
}

define i32 @narrow_float(i32 %x) {
; CHECK-LABEL: @narrow_float(
; CHECK-NOT: call
; CHECK: ret i32 %v
  %v = and i32 %x, 65535
  %f = sitofp i32 %v to float
  %r = call i32 @jeandle.round.float(float %f)
  ret i32 %r
}

define i32 @signed_byte(i8 %x) {
; CHECK-LABEL: @signed_byte(
; CHECK-NOT: call
; CHECK: sext i8 %x to i32
  %f = sitofp i8 %x to float
  %r = call i32 @jeandle.round.float(float %f)
  ret i32 %r
}

define i64 @wide_but_exact(i64 %x) {
; CHECK-LABEL: @wide_but_exact(
; CHECK-NOT: call
; CHECK: ret i64 %v
  %v = and i64 %x, 1099511627775
  %f = uitofp i64 %v to double
  %r = call i64 @jeandle.round.double(double %f)
  ret i64 %r
}

define i32 @lossy_float(i32 %x) {
; CHECK-LABEL: @lossy_float(
; CHECK: call i32 @jeandle.round.float
  %f = sitofp i32 %x to float
  %r = call i32 @jeandle.round.float(float %f)
  ret i32 %r
}

define i64 @lossy_double(i64 %x) {
; CHECK-LABEL: @lossy_double(
; CHECK: call i64 @jeandle.round.double
  %f = sitofp i64 %x to double
  %r = call i64 @jeandle.round.double(double %f)
  ret i64 %r
}

define i32 @unsigned_saturation(i32 %x) {
; CHECK-LABEL: @unsigned_saturation(
; CHECK: call i32 @jeandle.round.float
  %f = uitofp i32 %x to float
  %r = call i32 @jeandle.round.float(float %f)
  ret i32 %r
}

define i64 @lossy_mask(i64 %x) {
; CHECK-LABEL: @lossy_mask(
; CHECK: call i64 @jeandle.round.double
  %v = and i64 %x, 18014398509481983
  %f = uitofp i64 %v to double
  %r = call i64 @jeandle.round.double(double %f)
  ret i64 %r
}

define i32 @unrelated_select(i1 %cond, i32 %x, i32 %y) {
; CHECK-LABEL: @unrelated_select(
; CHECK: %r = select i1 %cond, i32 %x, i32 %y
; CHECK: ret i32 %r
  %r = select i1 %cond, i32 %x, i32 %y
  ret i32 %r
}

define i64 @bundled_round(i32 %x) {
; CHECK-LABEL: @bundled_round(
; CHECK: call i64 @jeandle.round.double{{.*}}[ "deopt"
  %f = sitofp i32 %x to double
  %r = call i64 @jeandle.round.double(double %f) [ "deopt"(i32 %x) ]
  ret i64 %r
}
define i32 @wrong_result_type(i32 %x) {
; CHECK-LABEL: @wrong_result_type(
; CHECK: call i32 @jeandle.round.double
  %f = sitofp i32 %x to double
  %r = call i32 @jeandle.round.double(double %f)
  ret i32 %r
}
define i64 @tail_round(double %x) {
; CHECK-LABEL: @tail_round(
; CHECK: musttail call i64 @jeandle.round.double
  %i = fptosi double %x to i32
  %f = sitofp i32 %i to double
  %r = musttail call i64 @jeandle.round.double(double %f)
  ret i64 %r
}
declare i32 @personality(...)
define i64 @invoked_round(i32 %x) personality ptr @personality {
; CHECK-LABEL: @invoked_round(
; CHECK: invoke i64 @jeandle.round.double
  %f = sitofp i32 %x to double
  %r = invoke i64 @jeandle.round.double(double %f) to label %normal unwind label %unwind
normal:
  ret i64 %r
unwind:
  %lp = landingpad { ptr, i32 } cleanup
  resume { ptr, i32 } %lp
}
