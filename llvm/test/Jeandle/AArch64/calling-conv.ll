; RUN: llc -O0 -mtriple=aarch64-unknown-linux-gnu < %s | FileCheck %s

define hotspotcc i32 @test_i32_args(i32 %a1, i32 %a2, i32 %a3, i32 %a4, i32 %a5, i32 %a6, i32 %a7, i32 %a8) {
; CHECK-LABEL: test_i32_args:
; CHECK:            add w10, w1, w2
; CHECK-NEXT:       add w13, w3, w4
; CHECK-NEXT:       add w11, w5, w6
; CHECK-NEXT:       add w12, w7, w0
; CHECK-NEXT:       add w10, w10, w13
; CHECK-NEXT:       add w11, w11, w12
; CHECK-NEXT:       add w0, w10, w11
  %sum1 = add i32 %a1, %a2
  %sum2 = add i32 %a3, %a4
  %sum3 = add i32 %a5, %a6
  %sum4 = add i32 %a7, %a8
  %tmp1 = add i32 %sum1, %sum2
  %tmp2 = add i32 %sum3, %sum4
  %ret1 = add i32 %tmp1, %tmp2
  ret i32 %ret1
}

define hotspotcc i64 @test_i64_args(i64 %a1, i64 %a2, i64 %a3, i64 %a4, i64 %a5, i64 %a6, i64 %a7, i64 %a8) {
; CHECK-LABEL: test_i64_args:
; CHECK:            add x10, x1, x2
; CHECK-NEXT:       add x13, x3, x4
; CHECK-NEXT:       add x11, x5, x6
; CHECK-NEXT:       add x12, x7, x0
; CHECK-NEXT:       add x10, x10, x13
; CHECK-NEXT:       add x11, x11, x12
; CHECK-NEXT:       add x0, x10, x11
  %sum1 = add i64 %a1, %a2
  %sum2 = add i64 %a3, %a4
  %sum3 = add i64 %a5, %a6
  %sum4 = add i64 %a7, %a8
  %tmp1 = add i64 %sum1, %sum2
  %tmp2 = add i64 %sum3, %sum4
  %ret1 = add i64 %tmp1, %tmp2
  ret i64 %ret1
}

@var = global [30 x i64] zeroinitializer
define hotspotcc void @test_reserved_regs() {
; CHECK-LABEL: test_reserved_regs:
; CHECK-NOT: ldr x8
; CHECK-NOT: ldr x9
; CHECK-NOT: ldr x28
; CHECK-NOT: str x8
; CHECK-NOT: str x9
; CHECK-NOT: str x28
  %val = load volatile [30 x i64], ptr @var
  store volatile [30 x i64] %val, ptr @var
  ret void
}

define hotspotcc void @test_compressed_oops() "use-compressed-oops" {
; CHECK-LABEL: test_compressed_oops:
; CHECK-NOT: ldr x27
; CHECK-NOT: str x27
  %val = load volatile [30 x i64], ptr @var
  store volatile [30 x i64] %val, ptr @var
  ret void
}
