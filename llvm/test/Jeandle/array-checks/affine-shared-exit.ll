; RUN: opt -passes='loop-simplify,lcssa,jeandle-affine-check-versioning' -verify-each -S %s | FileCheck %s
; RUN: opt -passes='jeandle-check-optimization' -verify-each -S %s | FileCheck %s --check-prefix=FULL

declare noundef range(i32 0, -2147483648) i32 @jeandle.arraylength(ptr addrspace(1) noundef) nounwind willreturn memory(read)
declare i32 @llvm.experimental.deoptimize.i32(...)
declare void @effect(i32)

; Two array checks share a failure block whose PHI selects the original index.
define i32 @shared_exit(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset) {
; CHECK-LABEL: define i32 @shared_exit(
; CHECK: affine.fast
; CHECK: fail:
; CHECK-NEXT: %bad = phi i32
; FULL-LABEL: define i32 @shared_exit(
; FULL: affine.slow
entry:
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %next, %body ]
  %index = add i32 %i, %offset
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %second, label %fail
second:
  call void @effect(i32 %index)
  %index2 = add i32 %index, 1
  %ok2 = icmp ult i32 %index2, %length
  br i1 %ok2, label %body, label %fail
body:
  call void @effect(i32 %index2)
  %next = add i32 %i, -2
  %again = icmp sgt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  %bad = phi i32 [ %index, %loop ], [ %index2, %second ]
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i32 %bad) ]
  ret i32 %r
exit:
  ret i32 42
}
!java-method-compilation = !{}
