; RUN: opt -S -verify-each -passes=libm-identity-folding %s | FileCheck %s
; RUN: opt -S -verify-each -passes='libm-identity-folding,libm-identity-folding' %s | FileCheck %s

!java-method-compilation = !{}

declare double @StubRoutines_dpow(double, double)
@SharedRuntime_dpow = alias double (double, double), ptr inttoptr (i64 4321 to ptr)

define double @one(double noundef %x) {
; CHECK-LABEL: define double @one(
; CHECK: %[[ORD:.*]] = fcmp ord double %x, %x
; CHECK: br i1 %[[ORD]], label %[[FAST:.*]], label %[[SLOW:.*]]
; CHECK: [[FAST]]:
; CHECK-NOT: call
; CHECK: br label %[[MERGE:.*]]
; CHECK: [[SLOW]]:
; CHECK: %[[CALL:.*]] = call double @StubRoutines_dpow(double %x, double 1.000000e+00) #{{[0-9]+}}
; CHECK-NOT: fcmp
; CHECK: br label %[[MERGE]]
; CHECK: [[MERGE]]:
; CHECK: %[[RESULT:.*]] = phi double [ %x, %[[FAST]] ], [ %[[CALL]], %[[SLOW]] ]
; CHECK: ret double %[[RESULT]]
  %r = call double @StubRoutines_dpow(double %x, double 1.0)
  ret double %r
}

define double @half(double noundef %x) {
; CHECK-LABEL: define double @half(
; CHECK: %[[POS:.*]] = fcmp ogt double %x, 0.000000e+00
; CHECK: br i1 %[[POS]], label %[[FAST:.*]], label %[[SLOW:.*]]
; CHECK: [[FAST]]:
; CHECK: %[[SQRT:.*]] = call double @llvm.sqrt.f64(double %x)
; CHECK: br label %[[MERGE:.*]]
; CHECK: [[SLOW]]:
; CHECK: %[[CALL:.*]] = call double @StubRoutines_dpow(double %x, double 5.000000e-01) #{{[0-9]+}}
; CHECK-NOT: fcmp
; CHECK: br label %[[MERGE]]
; CHECK: [[MERGE]]:
; CHECK: %[[RESULT:.*]] = phi double [ %[[SQRT]], %[[FAST]] ], [ %[[CALL]], %[[SLOW]] ]
; CHECK: ret double %[[RESULT]]
  %r = call double @StubRoutines_dpow(double %x, double 0.5)
  ret double %r
}

define double @shared_half(double noundef %x) {
; CHECK-LABEL: define double @shared_half(
; CHECK: fcmp ogt double %x, 0.000000e+00
; CHECK: call double @llvm.sqrt.f64(double %x)
; CHECK: call double inttoptr (i64 4321 to ptr)(double %x, double 5.000000e-01) #{{[0-9]+}}
; CHECK: phi double
  %r = call double inttoptr (i64 4321 to ptr)(double %x, double 0.5)
  ret double %r
}

define double @unstable_base(double %x) {
; CHECK-LABEL: define double @unstable_base(
; CHECK: %[[STABLE:.*]] = freeze double %x
; CHECK: fcmp ord double %[[STABLE]], %[[STABLE]]
; CHECK: call double @StubRoutines_dpow(double %[[STABLE]], double 1.000000e+00) #{{[0-9]+}}
; CHECK: phi double [ %[[STABLE]],
  %r = call double @StubRoutines_dpow(double %x, double 1.0)
  ret double %r
}

define double @poison_base() {
; CHECK-LABEL: define double @poison_base(
; CHECK: %[[STABLE:.*]] = freeze double poison
; CHECK: fcmp ogt double %[[STABLE]], 0.000000e+00
; CHECK: call double @llvm.sqrt.f64(double %[[STABLE]])
; CHECK: call double @StubRoutines_dpow(double %[[STABLE]], double 5.000000e-01)
  %r = call double @StubRoutines_dpow(double poison, double 0.5)
  ret double %r
}

define double @undef_base() {
; CHECK-LABEL: define double @undef_base(
; CHECK: %[[STABLE:.*]] = freeze double undef
; CHECK: fcmp ord double %[[STABLE]], %[[STABLE]]
; CHECK: call double @StubRoutines_dpow(double %[[STABLE]], double 1.000000e+00)
  %r = call double @StubRoutines_dpow(double undef, double 1.0)
  ret double %r
}

define double @minus_one(double %x) {
; CHECK-LABEL: define double @minus_one(
; CHECK-NOT: fdiv
; CHECK-NOT: fcmp
; CHECK: call double @StubRoutines_dpow(double %x, double -1.000000e+00)
  %r = call double @StubRoutines_dpow(double %x, double -1.0)
  ret double %r
}

define double @musttail_one(double %x, double %y) {
; CHECK-LABEL: define double @musttail_one(
; CHECK-NOT: fcmp
; CHECK: musttail call double @StubRoutines_dpow(double %x, double 1.000000e+00)
  %r = musttail call double @StubRoutines_dpow(double %x, double 1.0)
  ret double %r
}

define double @bundled_half(double %x) {
; CHECK-LABEL: define double @bundled_half(
; CHECK-NOT: fcmp
; CHECK: call double @StubRoutines_dpow(double %x, double 5.000000e-01) [ "deopt"(i32 7) ]
  %r = call double @StubRoutines_dpow(double %x, double 0.5) [ "deopt"(i32 7) ]
  ret double %r
}

define double @nested(double noundef %x) {
; CHECK-LABEL: define double @nested(
; CHECK: fcmp ord
; CHECK: call double @StubRoutines_dpow(double %x, double 1.000000e+00) #{{[0-9]+}}
; CHECK: phi double
; CHECK: fcmp ogt
; CHECK: call double @llvm.sqrt.f64
; CHECK: call double @StubRoutines_dpow(double {{.*}}, double 5.000000e-01) #{{[0-9]+}}
; CHECK: phi double
; CHECK: ret double
  %a = call double @StubRoutines_dpow(double %x, double 1.0)
  %b = call double @StubRoutines_dpow(double %a, double 0.5)
  ret double %b
}

; CHECK: attributes #{{[0-9]+}} = { "jeandle.pow.slow" }
