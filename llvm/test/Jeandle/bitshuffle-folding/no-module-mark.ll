; RUN: opt < %s -passes=bit-shuffle-folding -verify-each -S | FileCheck %s

declare i32 @llvm.x86.bmi.pext.32(i32, i32)
declare i32 @llvm.x86.bmi.pdep.32(i32, i32)
declare i64 @llvm.x86.bmi.pdep.64(i64, i64)

define i32 @composition(i32 %x, i32 %m) {
; CHECK-LABEL: @composition(
; CHECK: %inner = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
; CHECK: %outer = call i32 @llvm.x86.bmi.pdep.32(i32 %inner, i32 %m)
; CHECK: ret i32 %outer
  %inner = call i32 @llvm.x86.bmi.pext.32(i32 %x, i32 %m)
  %outer = call i32 @llvm.x86.bmi.pdep.32(i32 %inner, i32 %m)
  ret i32 %outer
}

define i64 @ones(i64 %m) {
; CHECK-LABEL: @ones(
; CHECK: %r = call i64 @llvm.x86.bmi.pdep.64(i64 -1, i64 %m)
; CHECK: ret i64 %r
  %r = call i64 @llvm.x86.bmi.pdep.64(i64 -1, i64 %m)
  ret i64 %r
}
