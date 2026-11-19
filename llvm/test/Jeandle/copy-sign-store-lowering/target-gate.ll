; RUN: opt -passes=copy-sign-store-lowering -mtriple=aarch64-unknown-linux-gnu -verify-each -S < %s | FileCheck %s
; RUN: opt -passes=copy-sign-store-lowering -mtriple=riscv64-unknown-linux-gnu -verify-each -S < %s | FileCheck %s
; RUN: opt -passes=copy-sign-store-lowering -verify-each -S < %s | FileCheck %s

declare double @llvm.copysign.f64(double, double)

define void @store(double %m, double %s, ptr %p) {
; CHECK-LABEL: @store(
; CHECK-NEXT: %r = call double @llvm.copysign.f64(double %m, double %s)
; CHECK-NEXT: store double %r, ptr %p, align 8
; CHECK-NEXT: ret void
  %r = call double @llvm.copysign.f64(double %m, double %s)
  store double %r, ptr %p, align 8
  ret void
}

!java-method-compilation = !{!0}
!0 = !{}
