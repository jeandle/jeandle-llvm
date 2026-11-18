; RUN: opt -passes=partial-escape-iterative -jeandle-pea-iterations=1 -verify-each -S %s | FileCheck %s

; InstCombine can prove an ordinary null guard redundant at the end of a PEA
; round. Remove its dead failure state before the next analysis, even when no
; widening permission remains for CheckPreparation to remove.
declare i32 @llvm.experimental.deoptimize.i32(...)

define i32 @nonnull_state(ptr noundef nonnull %p) {
; CHECK-LABEL: define i32 @nonnull_state(
; CHECK-NOT: deoptimize
; CHECK-NOT: poison
; CHECK-NOT: br i1
; CHECK: ret i32 42
entry:
  %null = icmp eq ptr %p, null
  br i1 %null, label %fail, label %done
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) ["deopt"(ptr %p)]
  ret i32 %r
done:
  ret i32 42
}

!java-method-compilation = !{}
