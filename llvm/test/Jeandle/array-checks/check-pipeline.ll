; RUN: opt -passes='jeandle-check-optimization' -verify-each -S %s | FileCheck %s

declare i1 @llvm.experimental.widenable.condition()
declare i32 @llvm.experimental.deoptimize.i32(...)
declare void @effect(i32)

define i32 @duplicates(i32 noundef %index, i32 noundef %length) {
; CHECK-LABEL: define i32 @duplicates(
; CHECK: call void @effect
; CHECK: ret i32 42
; CHECK: call i32 (...) @llvm.experimental.deoptimize.i32
; CHECK-NOT: call i32 (...) @llvm.experimental.deoptimize.i32
; CHECK: }
  %ok = icmp ult i32 %index, %length
  %wc1 = call i1 @llvm.experimental.widenable.condition()
  %g1 = and i1 %ok, %wc1
  br i1 %g1, label %next, label %fail1
next:
  call void @effect(i32 %index)
  %wc2 = call i1 @llvm.experimental.widenable.condition()
  %g2 = and i1 %ok, %wc2
  br i1 %g2, label %done, label %fail2
fail1:
  %request1 = select i1 %ok, i32 -139, i32 -26
  %r1 = call i32 (...) @llvm.experimental.deoptimize.i32(i32 %request1) [ "deopt"(i32 1) ]
  ret i32 %r1
fail2:
  %request2 = select i1 %ok, i32 -139, i32 -26
  %r2 = call i32 (...) @llvm.experimental.deoptimize.i32(i32 %request2) [ "deopt"(i32 2) ]
  ret i32 %r2
done:
  ret i32 42
}

!java-method-compilation = !{}
