; RUN: opt -passes=jeandle-check-preparation -verify-each -S %s | FileCheck %s

; A conditional virtual identity cannot be encoded in the deopt object pool.
; Preserve the original failure condition for these states, including values
; in inline scopes and references wrapped in pointer arithmetic.
declare noalias nonnull ptr addrspace(1) @jeandle.new_instance()
declare i1 @llvm.experimental.widenable.condition()
declare i32 @llvm.experimental.deoptimize.i32(...)

define i32 @nullable_select(i1 %choose, i1 %check, ptr addrspace(1) %arg, ptr addrspace(1) %other, i64 %offset) {
; CHECK-LABEL: define i32 @nullable_select(
; CHECK-NOT: widenable.condition
; CHECK: br i1 %check, label %done, label %fail
; CHECK: [ "deopt"(i32 7, ptr addrspace(1) %state) ]
entry:
  %allocation = call ptr addrspace(1) @jeandle.new_instance()
  %state = select i1 %choose, ptr addrspace(1) %allocation, ptr addrspace(1) null
  %wc = call i1 @llvm.experimental.widenable.condition()
  %guard = and i1 %check, %wc
  br i1 %guard, label %done, label %fail
done:
  ret i32 42
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) ["deopt"(i32 7, ptr addrspace(1) %state)]
  ret i32 %r
}

define i32 @mixed_select(i1 %choose, i1 %check, ptr addrspace(1) %arg, ptr addrspace(1) %other, i64 %offset) {
; CHECK-LABEL: define i32 @mixed_select(
; CHECK-NOT: widenable.condition
; CHECK: br i1 %check, label %done, label %fail
; CHECK: [ "deopt"(i32 7, ptr addrspace(1) %state) ]
entry:
  %allocation = call ptr addrspace(1) @jeandle.new_instance()
  %state = select i1 %choose, ptr addrspace(1) %allocation, ptr addrspace(1) %arg
  %wc = call i1 @llvm.experimental.widenable.condition()
  %guard = and i1 %check, %wc
  br i1 %guard, label %done, label %fail
done:
  ret i32 42
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) ["deopt"(i32 7, ptr addrspace(1) %state)]
  ret i32 %r
}

define i32 @wrapped_select(i1 %choose, i1 %check, ptr addrspace(1) %arg, ptr addrspace(1) %other, i64 %offset) {
; CHECK-LABEL: define i32 @wrapped_select(
; CHECK-NOT: widenable.condition
; CHECK: br i1 %check, label %done, label %fail
; CHECK: [ "deopt"(i32 7, ptr addrspace(1) %state) ]
entry:
  %allocation = call ptr addrspace(1) @jeandle.new_instance()
  %selected = select i1 %choose, ptr addrspace(1) %allocation, ptr addrspace(1) null
  %state = getelementptr i8, ptr addrspace(1) %selected, i64 %offset
  %wc = call i1 @llvm.experimental.widenable.condition()
  %guard = and i1 %check, %wc
  br i1 %guard, label %done, label %fail
done:
  ret i32 42
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) ["deopt"(i32 7, ptr addrspace(1) %state)]
  ret i32 %r
}

define i32 @direct_virtual(i1 %choose, i1 %check, ptr addrspace(1) %arg, ptr addrspace(1) %other, i64 %offset) {
; CHECK-LABEL: define i32 @direct_virtual(
; CHECK: %wc = call i1 @llvm.experimental.widenable.condition()
; CHECK: br i1 %guard, label %done, label %fail
; CHECK: [ "deopt"(i32 7, ptr addrspace(1) %state) ]
entry:
  %allocation = call ptr addrspace(1) @jeandle.new_instance()
  %state = getelementptr i8, ptr addrspace(1) %allocation, i64 %offset
  %wc = call i1 @llvm.experimental.widenable.condition()
  %guard = and i1 %check, %wc
  br i1 %guard, label %done, label %fail
done:
  ret i32 42
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) ["deopt"(i32 7, ptr addrspace(1) %state)]
  ret i32 %r
}

define i32 @material_select(i1 %choose, i1 %check, ptr addrspace(1) %arg, ptr addrspace(1) %other, i64 %offset) {
; CHECK-LABEL: define i32 @material_select(
; CHECK: %wc = call i1 @llvm.experimental.widenable.condition()
; CHECK: br i1 %guard, label %done, label %fail
; CHECK: [ "deopt"(i32 7, ptr addrspace(1) %state) ]
entry:
  %state = select i1 %choose, ptr addrspace(1) %arg, ptr addrspace(1) %other
  %wc = call i1 @llvm.experimental.widenable.condition()
  %guard = and i1 %check, %wc
  br i1 %guard, label %done, label %fail
done:
  ret i32 42
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) ["deopt"(i32 7, ptr addrspace(1) %state)]
  ret i32 %r
}

define i32 @nullable_phi(i1 %choose, i1 %check, ptr addrspace(1) %arg, ptr addrspace(1) %other, i64 %offset) {
; CHECK-LABEL: define i32 @nullable_phi(
; CHECK-NOT: widenable.condition
; CHECK: br i1 %check, label %done, label %fail
; CHECK: [ "deopt"(i32 7, ptr addrspace(1) %state) ]
entry:
  %allocation = call ptr addrspace(1) @jeandle.new_instance()
  br i1 %choose, label %left, label %right
left:
  br label %merge
right:
  br label %merge
merge:
  %state = phi ptr addrspace(1) [ %allocation, %left ], [ null, %right ]
  %wc = call i1 @llvm.experimental.widenable.condition()
  %guard = and i1 %check, %wc
  br i1 %guard, label %done, label %fail
done:
  ret i32 42
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) ["deopt"(i32 7, ptr addrspace(1) %state)]
  ret i32 %r
}

define i32 @material_phi(i1 %choose, i1 %check, ptr addrspace(1) %arg, ptr addrspace(1) %other, i64 %offset) {
; CHECK-LABEL: define i32 @material_phi(
; CHECK: %wc = call i1 @llvm.experimental.widenable.condition()
; CHECK: br i1 %guard, label %done, label %fail
; CHECK: [ "deopt"(i32 7, ptr addrspace(1) %state) ]
entry:
  br i1 %choose, label %left, label %right
left:
  br label %merge
right:
  br label %merge
merge:
  %state = phi ptr addrspace(1) [ %arg, %left ], [ %other, %right ]
  %wc = call i1 @llvm.experimental.widenable.condition()
  %guard = and i1 %check, %wc
  br i1 %guard, label %done, label %fail
done:
  ret i32 42
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) ["deopt"(i32 7, ptr addrspace(1) %state)]
  ret i32 %r
}

!java-method-compilation = !{}
