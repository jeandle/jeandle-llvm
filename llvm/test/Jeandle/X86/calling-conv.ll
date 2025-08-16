; RUN: llc -O0 -mtriple=x86_64-linux-gnu < %s | FileCheck %s

define hotspotcc i32 @test_i32_args(i32 %a1, i32 %a2, i32 %a3, i32 %a4, i32 %a5, i32 %a6) {
; CHECK-LABEL: test_i32_args:
; CHECK:       movl	%esi, %eax
; CHECK-NEXT:       addl	%edx, %eax
; CHECK-NEXT:       addl	%r8d, %ecx
; CHECK-NEXT:       addl	%edi, %r9d
; CHECK-NEXT:       addl	%ecx, %eax
; CHECK-NEXT:       addl	%r9d, %eax
  %sum1 = add i32 %a1, %a2
  %sum2 = add i32 %a3, %a4
  %sum3 = add i32 %a5, %a6
  %ret1 = add i32 %sum1, %sum2
  %ret2 = add i32 %ret1, %sum3
  ret i32 %ret2
}

define hotspotcc i64 @test_i64_args(i64 %a1, i64 %a2, i64 %a3, i64 %a4, i64 %a5, i64 %a6) {
; CHECK-LABEL: test_i64_args:
; CHECK:       movq	%rsi, %rax
; CHECK-NEXT:       addq	%rdx, %rax
; CHECK-NEXT:       addq	%r8, %rcx
; CHECK-NEXT:       addq	%rdi, %r9
; CHECK-NEXT:       addq	%rcx, %rax
; CHECK-NEXT:       addq	%r9, %rax
  %sum1 = add i64 %a1, %a2
  %sum2 = add i64 %a3, %a4
  %sum3 = add i64 %a5, %a6
  %ret1 = add i64 %sum1, %sum2
  %ret2 = add i64 %ret1, %sum3
  ret i64 %ret2
}

@var = global [30 x i64] zeroinitializer
define hotspotcc void @test_reserved_regs() {
; CHECK-LABEL: test_reserved_regs:
; CHECK: movq {{[0-9]+}}(%{{[a-z]+}}), %r12
; CHECK: movq %r12,
; CHECK-NOT: movq {{[0-9]+}}(%{{[a-z]+}}), %r15
; CHECK-NOT: movq %r15,
  %val = load volatile [30 x i64], ptr @var
  store volatile [30 x i64] %val, ptr @var
  ret void
}

define hotspotcc void @test_compressed_oops() "use-compressed-oops" {
; CHECK-LABEL: test_compressed_oops:
; CHECK-NOT: movq {{[0-9]+}}(%{{[a-z]+}}), %r12
; CHECK-NOT: movq {{[0-9]+}}(%{{[a-z]+}}), %r15
; CHECK-NOT: movq %r12,
; CHECK-NOT: movq %r15,
  %val = load volatile [30 x i64], ptr @var
  store volatile [30 x i64] %val, ptr @var
  ret void
}
