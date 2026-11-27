; RUN: opt -S -verify-each -passes='bit-shuffle-folding,instcombine' %s | FileCheck %s
; RUN: opt -S -verify-each -passes='bit-shuffle-folding,bit-shuffle-folding,instcombine' %s | FileCheck %s

!java-method-compilation = !{}

declare i32 @llvm.x86.bmi.pdep.32(i32, i32)
declare i64 @llvm.x86.bmi.pdep.64(i64, i64)

; Non-contiguous sparse constant mask (0x01010101, popcount = 4, L = 15).
define i1 @expand_zero_32_eq(i32 %x) {
; CHECK-LABEL: @expand_zero_32_eq(
; CHECK-NOT: pdep
; CHECK: %[[MASKED:.*]] = and i32 %x, 15
; CHECK: %[[TEST:.*]] = icmp eq i32 %[[MASKED]], 0
; CHECK: ret i1 %[[TEST]]
  %c = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 16843009)
  %r = icmp eq i32 %c, 0
  ret i1 %r
}

; Non-contiguous sparse 64-bit constant mask (0x0101010101010101, popcount = 8, L = 255).
define i1 @expand_zero_64_ne(i64 %x) {
; CHECK-LABEL: @expand_zero_64_ne(
; CHECK-NOT: pdep
; CHECK: %[[MASKED:.*]] = and i64 %x, 255
; CHECK: %[[TEST:.*]] = icmp ne i64 %[[MASKED]], 0
; CHECK: ret i1 %[[TEST]]
  %c = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 72340172838076673)
  %r = icmp ne i64 %c, 0
  ret i1 %r
}

; Swapped operands (0 on left), 64-bit alternating mask (0x5555555555555555, popcount = 32, L = 4294967295).
define i1 @expand_zero_64_eq_swapped(i64 %x) {
; CHECK-LABEL: @expand_zero_64_eq_swapped(
; CHECK-NOT: pdep
; CHECK: %[[MASKED:.*]] = and i64 %x, 4294967295
; CHECK: %[[TEST:.*]] = icmp eq i64 %[[MASKED]], 0
; CHECK: ret i1 %[[TEST]]
  %c = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 6148914691236517205)
  %r = icmp eq i64 0, %c
  ret i1 %r
}

; Swapped operands (0 on left), 32-bit alternating mask (0x55555555, popcount = 16, L = 65535).
define i1 @expand_zero_32_ne_swapped(i32 %x) {
; CHECK-LABEL: @expand_zero_32_ne_swapped(
; CHECK-NOT: pdep
; CHECK: %[[MASKED:.*]] = and i32 %x, 65535
; CHECK: %[[TEST:.*]] = icmp ne i32 %[[MASKED]], 0
; CHECK: ret i1 %[[TEST]]
  %c = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 1431655765)
  %r = icmp ne i32 0, %c
  ret i1 %r
}

; Boundary: zero mask (k = 0), expand result is always zero.
define i1 @expand_zero_mask_zero_32_eq(i32 %x) {
; CHECK-LABEL: @expand_zero_mask_zero_32_eq(
; CHECK-NOT: pdep
; CHECK: ret i1 true
  %c = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 0)
  %r = icmp eq i32 %c, 0
  ret i1 %r
}

define i1 @expand_zero_mask_zero_64_ne(i64 %x) {
; CHECK-LABEL: @expand_zero_mask_zero_64_ne(
; CHECK-NOT: pdep
; CHECK: ret i1 false
  %c = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 0)
  %r = icmp ne i64 %c, 0
  ret i1 %r
}

; Boundary: all-ones mask (k = W), L is all ones, instcombine drops the mask.
define i1 @expand_zero_mask_allones_32_eq(i32 %x) {
; CHECK-LABEL: @expand_zero_mask_allones_32_eq(
; CHECK-NOT: pdep
; CHECK-NOT: and
; CHECK: %[[TEST:.*]] = icmp eq i32 %x, 0
; CHECK: ret i1 %[[TEST]]
  %c = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 -1)
  %r = icmp eq i32 %c, 0
  ret i1 %r
}

define i1 @expand_zero_mask_allones_64_ne(i64 %x) {
; CHECK-LABEL: @expand_zero_mask_allones_64_ne(
; CHECK-NOT: pdep
; CHECK-NOT: and
; CHECK: %[[TEST:.*]] = icmp ne i64 %x, 0
; CHECK: ret i1 %[[TEST]]
  %c = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 -1)
  %r = icmp ne i64 %c, 0
  ret i1 %r
}

; Single-bit non-LSB mask (0x80000000, popcount = 1, L = 1).
define i1 @expand_zero_single_bit_32_eq(i32 %x) {
; CHECK-LABEL: @expand_zero_single_bit_32_eq(
; CHECK-NOT: pdep
; CHECK: %[[MASKED:.*]] = and i32 %x, 1
; CHECK: %[[TEST:.*]] = icmp eq i32 %[[MASKED]], 0
; CHECK: ret i1 %[[TEST]]
  %c = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 -2147483648)
  %r = icmp eq i32 %c, 0
  ret i1 %r
}

; Single-bit non-LSB 64-bit mask (1 << 62, popcount = 1, L = 1).
define i1 @expand_zero_single_bit_64_ne(i64 %x) {
; CHECK-LABEL: @expand_zero_single_bit_64_ne(
; CHECK-NOT: pdep
; CHECK: %[[MASKED:.*]] = and i64 %x, 1
; CHECK: %[[TEST:.*]] = icmp ne i64 %[[MASKED]], 0
; CHECK: ret i1 %[[TEST]]
  %c = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 4611686018427387904)
  %r = icmp ne i64 %c, 0
  ret i1 %r
}

; Input only has bits set above the low popcount(M) bits (x = 0x10, M = 0x01010101):
; must fold to true, proving it cannot be replaced with x == 0.
define i1 @expand_zero_high_bits_const_32() {
; CHECK-LABEL: @expand_zero_high_bits_const_32(
; CHECK-NOT: pdep
; CHECK: ret i1 true
  %c = call i32 @llvm.x86.bmi.pdep.32(i32 16, i32 16843009)
  %r = icmp eq i32 %c, 0
  ret i1 %r
}

; High bit set in input (bit 4) is masked away by L = 15.
define i1 @expand_zero_high_bits_or_32(i32 %x) {
; CHECK-LABEL: @expand_zero_high_bits_or_32(
; CHECK-NOT: pdep
; CHECK: %[[MASKED:.*]] = and i32 %x, 15
; CHECK: %[[TEST:.*]] = icmp eq i32 %[[MASKED]], 0
; CHECK: ret i1 %[[TEST]]
  %v = or i32 %x, 16
  %c = call i32 @llvm.x86.bmi.pdep.32(i32 %v, i32 16843009)
  %r = icmp eq i32 %c, 0
  ret i1 %r
}

; Dynamic mask: must NOT fold.
define i1 @expand_zero_dynamic_32(i32 %x, i32 %m) {
; CHECK-LABEL: @expand_zero_dynamic_32(
; CHECK: %c = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 %m)
; CHECK: %r = icmp eq i32 %c, 0
; CHECK: ret i1 %r
  %c = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 %m)
  %r = icmp eq i32 %c, 0
  ret i1 %r
}

define i1 @expand_zero_dynamic_64(i64 %x, i64 %m) {
; CHECK-LABEL: @expand_zero_dynamic_64(
; CHECK: %c = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 %m)
; CHECK: %r = icmp ne i64 %c, 0
; CHECK: ret i1 %r
  %c = call i64 @llvm.x86.bmi.pdep.64(i64 %x, i64 %m)
  %r = icmp ne i64 %c, 0
  ret i1 %r
}

; Multi-use pdep with constant mask: must NOT fold.
define i1 @expand_zero_shared_const_32(i32 %x, ptr %out) {
; CHECK-LABEL: @expand_zero_shared_const_32(
; CHECK: %c = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 16843009)
; CHECK: store i32 %c, ptr %out
; CHECK: %r = icmp eq i32 %c, 0
; CHECK: ret i1 %r
  %c = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 16843009)
  store i32 %c, ptr %out
  %r = icmp eq i32 %c, 0
  ret i1 %r
}
