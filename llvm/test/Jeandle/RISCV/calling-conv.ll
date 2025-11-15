; RUN: llc -O0 -mtriple=riscv64-unknown-linux-gnu < %s | FileCheck %s

define hotspotcc i32 @test_i32_args(i32 %a1, i32 %a2, i32 %a3, i32 %a4, i32 %a5, i32 %a6, i32 %a7, i32 %a8) {
; CHECK-LABEL: test_i32_args:
; CHECK:            sd a0, 8(sp)
; CHECK:            mv a0, a2
; CHECK:            ld a2, 8(sp)
; CHECK:            addw a0, a1, a0
; CHECK-NEXT:       addw a3, a3, a4
; CHECK-NEXT:       addw a1, a5, a6
; CHECK-NEXT:       addw a2, a7, a2
; CHECK-NEXT:       addw a0, a0, a3
; CHECK-NEXT:       addw a1, a1, a2
; CHECK-NEXT:       addw a0, a0, a1
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
; CHECK:            sd a0, 8(sp)
; CHECK:            mv a0, a2
; CHECK:            ld a2, 8(sp)
; CHECK:            add a0, a1, a0
; CHECK-NEXT:       add a3, a3, a4
; CHECK-NEXT:       add a1, a5, a6
; CHECK-NEXT:       add a2, a7, a2
; CHECK-NEXT:       add a0, a0, a3
; CHECK-NEXT:       add a1, a1, a2
; CHECK-NEXT:       add a0, a0, a1
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
; CHECK-NOT: ld t0
; CHECK-NOT: ld t1
; CHECK-NOT: ld tp
; CHECK-NOT: ld s7
; CHECK-NOT: sd t0
; CHECK-NOT: sd t1
; CHECK-NOT: sd tp
; CHECK-NOT: sd s7
  %val = load volatile [30 x i64], ptr @var
  store volatile [30 x i64] %val, ptr @var
  ret void
}

define hotspotcc void @test_compressed_oops() "use-compressed-oops" {
; CHECK-LABEL: test_compressed_oops:
; CHECK-NOT: ld t0
; CHECK-NOT: ld t1
; CHECK-NOT: ld tp
; CHECK-NOT: ld s11
; CHECK-NOT: ld s7
; CHECK-NOT: sd t0
; CHECK-NOT: sd t1
; CHECK-NOT: sd tp
; CHECK-NOT: sd s11
; CHECK-NOT: sd s7
  %val = load volatile [30 x i64], ptr @var
  store volatile [30 x i64] %val, ptr @var
  ret void
}
