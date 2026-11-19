; RUN: opt -S -verify-each -passes='bit-shuffle-folding,instcombine' %s | FileCheck %s
; RUN: opt -S -verify-each -passes='bit-shuffle-folding,bit-shuffle-folding,instcombine' %s | FileCheck %s
!java-method-compilation = !{}
declare i32 @llvm.x86.bmi.pext.32(i32, i32)
declare i64 @llvm.x86.bmi.pext.64(i64, i64)
declare i32 @llvm.x86.bmi.pdep.32(i32, i32)

define i1 @compress_zero_32_eq(i32 %x, i32 %m) {
; CHECK-LABEL: @compress_zero_32_eq(
; CHECK-NOT: pext
; CHECK: %[[MASKED:.*]] = and i32 %x, %m
; CHECK: %[[TEST:.*]] = icmp eq i32 %[[MASKED]], 0
; CHECK: ret i1 %[[TEST]]
  %c = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
  %r = icmp eq i32 %c, 0
  ret i1 %r
}

define i1 @compress_zero_64_ne(i64 %x, i64 %m) {
; CHECK-LABEL: @compress_zero_64_ne(
; CHECK-NOT: pext
; CHECK: %[[MASKED:.*]] = and i64 %x, %m
; CHECK: %[[TEST:.*]] = icmp ne i64 %[[MASKED]], 0
; CHECK: ret i1 %[[TEST]]
  %c = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m)
  %r = icmp ne i64 %c, 0
  ret i1 %r
}

define i1 @compress_zero_64_eq_swapped(i64 %x, i64 %m) {
; CHECK-LABEL: @compress_zero_64_eq_swapped(
; CHECK-NOT: pext
; CHECK: %[[MASKED:.*]] = and i64 %x, %m
; CHECK: %[[TEST:.*]] = icmp eq i64 %[[MASKED]], 0
; CHECK: ret i1 %[[TEST]]
  %c = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m)
  %r = icmp eq i64 0, %c
  ret i1 %r
}

define i1 @compress_zero_32_ne_swapped(i32 %x, i32 %m) {
; CHECK-LABEL: @compress_zero_32_ne_swapped(
; CHECK-NOT: pext
; CHECK: %[[MASKED:.*]] = and i32 %x, %m
; CHECK: %[[TEST:.*]] = icmp ne i32 %[[MASKED]], 0
; CHECK: ret i1 %[[TEST]]
  %c = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
  %r = icmp ne i32 0, %c
  ret i1 %r
}

define i1 @compress_shared(i64 %x, i64 %m, ptr %out) {
; CHECK-LABEL: @compress_shared(
; CHECK: %c = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m)
; CHECK: store i64 %c
; CHECK: icmp eq i64 %c, 0
  %c = call i64 @llvm.x86.bmi.pext.64(i64 %x, i64 %m)
  store i64 %c, ptr %out
  %r = icmp eq i64 %c, 0
  ret i1 %r
}

define i1 @expand_zero(i32 %x, i32 %m) {
; CHECK-LABEL: @expand_zero(
; CHECK: call i32 @llvm.x86.bmi.pdep.32
; CHECK: icmp eq i32 %c, 0
  %c = call i32 @llvm.x86.bmi.pdep.32(i32 %x, i32 %m)
  %r = icmp eq i32 %c, 0
  ret i1 %r
}
