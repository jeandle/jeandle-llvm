; RUN: opt -passes='jeandle-check-optimization,instcombine,simplifycfg' -verify-each -S %s | FileCheck %s

; The Jeandle-specific proof requires a Java method compilation.
define i1 @no_java_metadata(i32 noundef %x, i32 noundef range(i32 1, -2147483648) %length) {
; CHECK-LABEL: define i1 @no_java_metadata(
; CHECK: icmp ult
; CHECK: ret i1 %
  %last = add i32 %length, -1
  %lo = call i32 @llvm.smax.i32(i32 %x, i32 0)
  %index = call i32 @llvm.smin.i32(i32 %lo, i32 %last)
  %ok = icmp ult i32 %index, %length
  ret i1 %ok
}

declare i32 @llvm.smin.i32(i32, i32)
declare i32 @llvm.smax.i32(i32, i32)
