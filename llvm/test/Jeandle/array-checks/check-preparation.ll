; RUN: opt -passes='instcombine,jeandle-check-preparation,simplifycfg' -verify-each -S %s | FileCheck %s

declare i1 @llvm.experimental.widenable.condition()
declare i32 @llvm.experimental.deoptimize.i32(...)

define i32 @nonnull(ptr noundef nonnull %receiver) {
; CHECK-LABEL: define i32 @nonnull(
; CHECK-NOT: widenable.condition
; CHECK-NOT: deoptimize
; CHECK: ret i32 42
entry:
  %ok = icmp ne ptr %receiver, null
  %wc = call i1 @llvm.experimental.widenable.condition()
  %g = and i1 %ok, %wc
  br i1 %g, label %done, label %fail
done:
  ret i32 42
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -139) ["deopt"(ptr %receiver)]
  ret i32 %r
}

define i32 @nullable(ptr noundef %receiver) {
; CHECK-LABEL: define i32 @nullable(
; CHECK: %ok = icmp ne ptr %receiver, null
; CHECK: %wc = call i1 @llvm.experimental.widenable.condition()
; CHECK: %g = and i1 %ok, %wc
; CHECK: br i1 %g
; CHECK: call i32 (...) @llvm.experimental.deoptimize.i32
entry:
  %ok = icmp ne ptr %receiver, null
  %wc = call i1 @llvm.experimental.widenable.condition()
  %g = and i1 %ok, %wc
  br i1 %g, label %done, label %fail
done:
  ret i32 42
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) ["deopt"(ptr %receiver)]
  ret i32 %r
}

!java-method-compilation = !{}
