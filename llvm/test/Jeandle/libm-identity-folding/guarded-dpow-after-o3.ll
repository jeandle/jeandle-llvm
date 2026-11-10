; RUN: opt -S -verify-each -passes='function(libm-identity-folding),default<O3>,function(libm-identity-folding)' %s | FileCheck %s

!java-method-compilation = !{}
declare double @StubRoutines_dpow(double, double) nounwind willreturn memory(none)

; CSE may merge the two residual calls. The late pass must not guard them again.
define double @two_ones(double noundef %x) {
; CHECK-LABEL: define double @two_ones(
; CHECK: fcmp {{ord|uno}} double %x,
; CHECK-NOT: fcmp
; CHECK: call double @StubRoutines_dpow(double %x, double 1.000000e+00) #[[SLOW:[0-9]+]]
; CHECK-NOT: fcmp
; CHECK: ret double
  %a = call double @StubRoutines_dpow(double %x, double 1.0)
  %b = call double @StubRoutines_dpow(double %x, double 1.0)
  %sum = fadd double %a, %b
  ret double %sum
}

define double @two_halves(double noundef %x) {
; CHECK-LABEL: define double @two_halves(
; CHECK: fcmp ogt double %x, 0.000000e+00
; CHECK: call double @llvm.sqrt.f64(double %x)
; CHECK-NOT: fcmp
; CHECK-NOT: @llvm.sqrt
; CHECK: call double @StubRoutines_dpow(double %x, double 5.000000e-01) #[[SLOW]]
; CHECK-NOT: fcmp
; CHECK-NOT: @llvm.sqrt
; CHECK: ret double
  %a = call double @StubRoutines_dpow(double %x, double 0.5)
  %b = call double @StubRoutines_dpow(double %x, double 0.5)
  %sum = fadd double %a, %b
  ret double %sum
}

define double @branch_halves(double noundef %x, i1 %choose) {
; CHECK-LABEL: define double @branch_halves(
; CHECK: fcmp ogt double %x, 0.000000e+00
; CHECK: call double @llvm.sqrt.f64(double %x)
; CHECK-NOT: fcmp
; CHECK-NOT: @llvm.sqrt
; CHECK: call double @StubRoutines_dpow(double %x, double 5.000000e-01) #[[SLOW]]
; CHECK-NOT: fcmp
; CHECK: ret double
  br i1 %choose, label %left, label %right
left:
  %a = call double @StubRoutines_dpow(double %x, double 0.5)
  br label %merge
right:
  %b = call double @StubRoutines_dpow(double %x, double 0.5)
  br label %merge
merge:
  %r = phi double [ %a, %left ], [ %b, %right ]
  ret double %r
}

; CHECK: attributes #[[SLOW]] = { {{.*}}"jeandle.pow.slow"{{.*}} }
