; RUN: opt -passes='jeandle-check-optimization' -verify-each -S %s | FileCheck %s --check-prefix=FULL
; RUN: opt -passes='loop-simplify,lcssa,jeandle-affine-check-versioning' -verify-each -S %s | FileCheck %s

declare noundef range(i32 0, -2147483648) i32 @jeandle.arraylength(ptr addrspace(1) noundef) nounwind willreturn memory(read)
declare i32 @llvm.experimental.deoptimize.i32(...)
declare void @effect(i32)

define i32 @scaled(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset, i32 noundef %scale) {
; FULL-LABEL: define i32 @scaled(
; FULL: %affine.step = sext i32 %scale to i64
; FULL: %affine.low = select
; FULL: %affine.high = select
; FULL: br i1 {{.*}}, label %{{.*}}, label %loop.affine.slow.preheader
; FULL: %ok.affine.slow = icmp ult
; FULL: loop:
; FULL-NOT: icmp ult
; FULL: call void @effect
; FULL-NOT: label %fail
; FULL: !llvm.loop
; CHECK-LABEL: define i32 @scaled(
; CHECK: affine.fast
; CHECK: %ok.affine.slow = icmp ult
; CHECK: loop:
; CHECK: br i1 true
entry:
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, %scale
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

define i32 @undefined_step(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset, i32 %scale) {
; CHECK-LABEL: define i32 @undefined_step(
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
  %scaled = mul i32 %i, %scale
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

define i32 @poisoned_step(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset, i32 noundef %raw, i32 noundef %shift) {
; CHECK-LABEL: define i32 @poisoned_step(
; CHECK-NOT: affine.fast
; CHECK: %ok = icmp ult
; CHECK: br i1 %ok
entry:
  %scale = shl i32 %raw, %shift
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, %scale
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

define i32 @signed_upper(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset, i32 noundef %scale) {
; CHECK-LABEL: define i32 @signed_upper(
; CHECK: affine.fast
; CHECK: %ok.affine.slow = icmp slt
; CHECK: loop:
; CHECK: br i1 true
entry:
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, %scale
  %index = add i32 %scaled, %offset
  %ok = icmp slt i32 %index, %length
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

define i32 @unsafe_step(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset, i32 noundef %divisor) {
; CHECK-LABEL: define i32 @unsafe_step(
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
  %scale = udiv i32 1, %divisor
  %scaled = mul i32 %i, %scale
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

define i32 @dynamic_controller(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset, i32 noundef %scale, i32 noundef %controllerstep) {
; CHECK-LABEL: define i32 @dynamic_controller(
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
  %scaled = mul i32 %i, %scale
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail, !prof !0
body:
  call void @effect(i32 %index)
  %next = add i32 %i, %controllerstep
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i32 %i, i32 %index) ]
  ret i32 %r
exit:
  ret i32 42
}

; A full-width unsigned controller requires 128-bit endpoint arithmetic.
define i32 @wide_unsigned_step(i64 noundef %limit, i64 noundef %offset, i64 noundef %scale) {
; CHECK-LABEL: define i32 @wide_unsigned_step(
; CHECK: %affine.step = sext i64 %scale to i128
; CHECK: %affine.low = select i1 {{.*}}, i128
; CHECK: %affine.high = select i1 {{.*}}, i128
; CHECK: affine.fast
; CHECK: %ok.affine.slow = icmp ult i64
; CHECK: loop:
; CHECK: br i1 true
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %body ]
  %scaled = mul i64 %i, %scale
  %index = add i64 %scaled, %offset
  %ok = icmp ult i64 %index, 1000
  br i1 %ok, label %body, label %fail
body:
  %narrow = trunc i64 %index to i32
  call void @effect(i32 %narrow)
  %next = add i64 %i, 1
  %again = icmp ule i64 %next, %limit
  br i1 %again, label %loop, label %exit
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i64 %i, i64 %index) ]
  ret i32 %r
exit:
  ret i32 42
}
!0 = !{!"branch_weights", i32 1048575, i32 1}
!java-method-compilation = !{}
