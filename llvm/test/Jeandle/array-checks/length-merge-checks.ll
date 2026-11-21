; RUN: opt -passes='function(jeandle-array-length-optimization,jeandle-check-optimization),default<O3>' -verify-each -S %s | FileCheck %s
; The same live Java array has its length read on every predecessor.
declare noundef range(i32 0, -2147483648) i32 @jeandle.arraylength(ptr addrspace(1) noundef) nounwind willreturn memory(read)
declare void @effect(i32)
declare i32 @llvm.experimental.deoptimize.i32(...)

define i32 @length_join(ptr addrspace(1) noundef nonnull %a, i1 noundef %c, i32 noundef %index) {
; CHECK-LABEL: define i32 @length_join(
; CHECK: call i32 @jeandle.arraylength
; CHECK: br i1
; CHECK: merge:
; CHECK: call void @effect
; CHECK-NOT: call i32 @jeandle.arraylength
; CHECK-NOT: icmp ult
; CHECK-NOT: br i1
; CHECK: ret i32 42
entry:
  br i1 %c, label %left, label %right
left:
  %l = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %ok_l = icmp ult i32 %index, %l
  br i1 %ok_l, label %left_ok, label %fail
left_ok:
  call void @effect(i32 1)
  br label %merge
right:
  %r = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %ok_r = icmp ult i32 %index, %r
  br i1 %ok_r, label %right_ok, label %fail
right_ok:
  call void @effect(i32 2)
  br label %merge
merge:
  %len = phi i32 [ %l, %left_ok ], [ %r, %right_ok ]
  call void @effect(i32 %len)
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %ok = icmp ult i32 %index, %again
  br i1 %ok, label %done, label %fail
done:
  ret i32 42
fail:
  %d = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) ["deopt"(i32 %index)]
  ret i32 %d
}
!java-method-compilation = !{}
