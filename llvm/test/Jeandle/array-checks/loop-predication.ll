; RUN: opt -passes='jeandle-check-optimization' -verify-each -S %s | FileCheck %s

declare i1 @llvm.experimental.widenable.condition()
declare i32 @llvm.experimental.deoptimize.i32(...)
declare void @effect(i32)

define i32 @forward(i32 noundef %n, i32 noundef %length) {
; CHECK-LABEL: define i32 @forward(
; CHECK-NOT: call i1 @llvm.experimental.widenable.condition
; CHECK: loop.preheader:
; CHECK: br i1
; CHECK: loop:
; CHECK-NOT: br i1
; CHECK: call void @effect
; CHECK-NOT: br i1
; CHECK: br i1 %again, label %loop, label %exit.loopexit
; CHECK: call i32 (...) @llvm.experimental.deoptimize.i32
entry:
  %start = add i32 %n, -1
  %enter = icmp sgt i32 %n, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %ok = icmp ult i32 %i, %length
  %wc = call i1 @llvm.experimental.widenable.condition()
  %guard = and i1 %ok, %wc
  br i1 %guard, label %body, label %fail, !prof !0
body:
  call void @effect(i32 %i)
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %n
  br i1 %again, label %loop, label %exit
fail:
  %request = select i1 %ok, i32 -139, i32 -26
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 %request) [ "deopt"(i32 %i) ]
  ret i32 %r
exit:
  ret i32 42
}

define i32 @reverse(i32 noundef %n, i32 noundef %length) {
; CHECK-LABEL: define i32 @reverse(
; CHECK-NOT: call i1 @llvm.experimental.widenable.condition
; CHECK: loop.preheader:
; CHECK: br i1
; CHECK: loop:
; CHECK-NOT: br i1
; CHECK: call void @effect
; CHECK-NOT: br i1
; CHECK: br i1 %again, label %loop, label %exit.loopexit
; CHECK: call i32 (...) @llvm.experimental.deoptimize.i32
entry:
  %start = add i32 %n, -1
  %enter = icmp sgt i32 %n, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ %start, %preheader ], [ %next, %body ]
  %ok = icmp ult i32 %i, %length
  %wc = call i1 @llvm.experimental.widenable.condition()
  %guard = and i1 %ok, %wc
  br i1 %guard, label %body, label %fail, !prof !0
body:
  call void @effect(i32 %i)
  %next = add i32 %i, -1
  %again = icmp sge i32 %next, 0
  br i1 %again, label %loop, label %exit
fail:
  %request = select i1 %ok, i32 -139, i32 -26
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 %request) [ "deopt"(i32 %i) ]
  ret i32 %r
exit:
  ret i32 42
}

!0 = !{!"branch_weights", i32 1048575, i32 1}
!java-method-compilation = !{}
