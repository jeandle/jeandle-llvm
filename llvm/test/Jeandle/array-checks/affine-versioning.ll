; RUN: opt -passes='loop-simplify,lcssa,jeandle-affine-check-versioning' -verify-each -S %s | FileCheck %s
; RUN: opt -passes='jeandle-check-optimization' -verify-each -S %s | FileCheck %s --check-prefix=LATE
; RUN: opt -jeandle-affine-check-versioning=false -passes='loop-simplify,lcssa,jeandle-check-optimization' -verify-each -S %s | FileCheck %s --check-prefix=STANDARD

declare noundef range(i32 0, -2147483648) i32 @jeandle.arraylength(ptr addrspace(1) noundef) nounwind willreturn memory(read)
declare i32 @llvm.experimental.deoptimize.i32(...)
declare void @effect(i32)

define i32 @scaled(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset) {
; CHECK-LABEL: define i32 @scaled(
; CHECK: affine.check
; CHECK: br i1 {{.*}}, label %{{.*}}affine.fast{{.*}}, label %{{.*}}affine.slow
; CHECK: loop.affine.slow:
; CHECK: %ok.affine.slow = icmp ult
; CHECK: loop:
; CHECK: br i1 true, label %body, label %fail
; STANDARD-LABEL: define i32 @scaled(
; STANDARD: %ok = icmp ult
; STANDARD: br i1 %ok
entry:
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, 3
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail, !prof !0
body:
  call void @effect(i32 %index)
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i32 %i, i32 %index) ]
  ret i32 %r
exit:
  ret i32 42
}
@receiver = external global ptr addrspace(1)

define i32 @reverse_stride(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset) {
; CHECK-LABEL: define i32 @reverse_stride(
; CHECK: affine.fast
; CHECK: %ok.affine.slow = icmp ult
entry:
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %enter = icmp slt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, 3
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail, !prof !0
body:
  call void @effect(i32 %index)
  %next = add i32 %i, -2
  %again = icmp sgt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i32 %i, i32 %index) ]
  ret i32 %r
exit:
  ret i32 42
}
define i32 @exit_phi(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset) {
; CHECK-LABEL: define i32 @exit_phi(
; CHECK: affine.fast
; CHECK: %ok.affine.slow = icmp ult
entry:
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, 3
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail, !prof !0
body:
  call void @effect(i32 %index)
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i32 %i, i32 %index) ]
  ret i32 %r
exit:
  %result = phi i32 [ 0, %entry ], [ %next, %body ]
  ret i32 %result
}
define i32 @narrowing(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset) {
; CHECK-LABEL: define i32 @narrowing(
; CHECK-NOT: affine.fast
; CHECK: %ok = icmp ult
; CHECK: br i1 %ok
entry:
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, 3
  %raw = add i32 %scaled, %offset
  %small = trunc i32 %raw to i8
  %index = sext i8 %small to i32
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail, !prof !0
body:
  call void @effect(i32 %index)
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i32 %i, i32 %index) ]
  ret i32 %r
exit:
  ret i32 42
}
define i32 @mutable_receiver(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset) {
; CHECK-LABEL: define i32 @mutable_receiver(
; CHECK-NOT: affine.fast
; CHECK: %ok = icmp ult
; CHECK: br i1 %ok
entry:

  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, 3
  %index = add i32 %scaled, %offset
  %array = load ptr addrspace(1), ptr @receiver
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %array)
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail, !prof !0
body:
  call void @effect(i32 %index)
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i32 %i, i32 %index) ]
  ret i32 %r
exit:
  ret i32 42
}
define i32 @undefined_limit(ptr addrspace(1) noundef nonnull %a, i32 %end, i32 noundef %offset) {
; CHECK-LABEL: define i32 @undefined_limit(
; CHECK-NOT: affine.fast
; CHECK: %ok = icmp ult
; CHECK: br i1 %ok
entry:
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, 3
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail, !prof !0
body:
  call void @effect(i32 %index)
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i32 %i, i32 %index) ]
  ret i32 %r
exit:
  ret i32 42
}
define i32 @widened_controller(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset) {
; CHECK-LABEL: define i32 @widened_controller(
; CHECK: affine.fast
entry:
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  %limit = zext nneg i32 %end to i64
  br label %nonnull
nonnull:
  %off64 = zext i32 %offset to i64
  %len64 = zext i32 %length to i64
  br label %loop
loop:
  %i = phi i64 [ 0, %nonnull ], [ %next, %body ]
  %scaled = mul i64 %i, 3
  %index = add i64 %scaled, %off64
  %ok = icmp ult i64 %index, %len64
  br i1 %ok, label %body, label %fail, !prof !0
body:
  call void @effect(i32 %offset)
  %next = add i64 %i, 1
  %again = icmp ne i64 %next, %limit
  br i1 %again, label %loop, label %exit
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i64 %i, i64 %index) ]
  ret i32 %r
exit:
  ret i32 42
}
define i32 @poisoned_limit(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset) {
; CHECK-LABEL: define i32 @poisoned_limit(
; CHECK-NOT: affine.fast
; CHECK: %ok = icmp ult
entry:
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %enter = icmp sgt i32 %end, 0
  br label %preheader
preheader:
  %limit = zext nneg i32 %end to i64
  br label %nonnull
nonnull:
  %off64 = zext i32 %offset to i64
  %len64 = zext i32 %length to i64
  br label %loop
loop:
  %i = phi i64 [ 0, %nonnull ], [ %next, %body ]
  %scaled = mul i64 %i, 3
  %index = add i64 %scaled, %off64
  %ok = icmp ult i64 %index, %len64
  br i1 %ok, label %body, label %fail, !prof !0
body:
  call void @effect(i32 %offset)
  %next = add i64 %i, 1
  %again = icmp ne i64 %next, %limit
  br i1 %again, label %loop, label %exit
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i64 %i, i64 %index) ]
  ret i32 %r
exit:
  ret i32 42
}
define i32 @loop_local_length(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset) {
; CHECK-LABEL: define i32 @loop_local_length(
; CHECK-NOT: affine.fast
; CHECK: %ok = icmp ult
; LATE-LABEL: define i32 @loop_local_length(
; LATE: affine.check
; LATE: affine.slow
entry:
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, 3
  %index = add i32 %scaled, %offset
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail, !prof !0
body:
  call void @effect(i32 %index)
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i32 %i, i32 %index) ]
  ret i32 %r
exit:
  ret i32 42
}
!0 = !{!"branch_weights", i32 1048575, i32 1}
!java-method-compilation = !{}
