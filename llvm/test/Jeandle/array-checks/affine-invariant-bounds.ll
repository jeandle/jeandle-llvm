; RUN: opt -passes='loop-simplify,lcssa,jeandle-affine-check-versioning' -verify-each -S %s | FileCheck %s
; RUN: opt -passes='jeandle-check-optimization' -verify-each -S %s | FileCheck %s --check-prefix=FULL

declare noundef range(i32 0, -2147483648) i32 @jeandle.arraylength(ptr addrspace(1) noundef) nounwind willreturn memory(read)
declare i32 @llvm.experimental.deoptimize.i32(...)
declare void @effect(i32)
define i32 @constant_bound(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset) {
; CHECK-LABEL: define i32 @constant_bound(
; CHECK: affine.fast
; CHECK: %ok.affine.slow = icmp ult
; CHECK: loop:
; CHECK: br i1 true
; FULL-LABEL: define i32 @constant_bound(
; FULL: br i1 {{.*}}, label %{{.*}}, label %{{.*}}affine.slow
entry:
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, 3
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, 1024
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

define i32 @invariant_bound(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset, i32 noundef range(i32 0, -2147483648) %bound) {
; CHECK-LABEL: define i32 @invariant_bound(
; CHECK: affine.fast
; CHECK: %ok.affine.slow = icmp ult
; CHECK: loop:
; CHECK: br i1 true
; FULL-LABEL: define i32 @invariant_bound(
; FULL: br i1 {{.*}}, label %{{.*}}, label %{{.*}}affine.slow
entry:
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, 3
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, %bound
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

define i32 @signed_bound(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset, i32 noundef %bound) {
; CHECK-LABEL: define i32 @signed_bound(
; CHECK-NOT: affine.fast
; CHECK: %ok = icmp ult
; FULL-LABEL: define i32 @signed_bound(
; FULL-NOT: affine.fast
; FULL: ret i32
entry:
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, 3
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, %bound
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

define i32 @undefined_bound(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset, i32 range(i32 0, -2147483648) %bound) {
; CHECK-LABEL: define i32 @undefined_bound(
; CHECK-NOT: affine.fast
; CHECK: %ok = icmp ult
; FULL-LABEL: define i32 @undefined_bound(
; FULL-NOT: affine.fast
; FULL: ret i32
entry:
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, 3
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, %bound
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

define i32 @poison_bound(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset, i32 noundef %raw) {
; CHECK-LABEL: define i32 @poison_bound(
; CHECK-NOT: affine.fast
; CHECK: %ok = icmp ult
; FULL-LABEL: define i32 @poison_bound(
; FULL-NOT: affine.fast
; FULL: ret i32
entry:
  %bound = add nuw i32 %raw, 1
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, 3
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, %bound
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

define i32 @same_step_n2(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset) {
; CHECK-LABEL: define i32 @same_step_n2(
; CHECK: affine.fast
; CHECK: %ok.affine.slow = icmp ult
; FULL-LABEL: define i32 @same_step_n2(
; FULL: br i1 {{.*}}, label %{{.*}}, label %{{.*}}affine.slow
entry:
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %enter = icmp slt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, 1
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

define i32 @same_step_n3(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset) {
; CHECK-LABEL: define i32 @same_step_n3(
; CHECK: affine.fast
; CHECK: %ok.affine.slow = icmp ult
; FULL-LABEL: define i32 @same_step_n3(
; FULL: br i1 {{.*}}, label %{{.*}}, label %{{.*}}affine.slow
entry:
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %enter = icmp slt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, 1
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail, !prof !0
body:
  call void @effect(i32 %index)
  %next = add i32 %i, -3
  %again = icmp sgt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i32 %i, i32 %index) ]
  ret i32 %r
exit:
  ret i32 42
}

define i32 @constrained_clone(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset) {
; CHECK-LABEL: define i32 @constrained_clone(
; CHECK-NOT: affine.fast
; CHECK: %ok = icmp ult
; FULL-LABEL: define i32 @constrained_clone(
; FULL-NOT: affine.fast
; FULL: ret i32
entry:
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, 3
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, 1024
  br i1 %ok, label %body, label %fail, !prof !0
body:
  call void @effect(i32 %index)
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit, !loop_constrainer.loop.clone !1
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i32 %i, i32 %index) ]
  ret i32 %r
exit:
  ret i32 42
}

define i32 @nneg_extended_bound(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset, i32 noundef range(i32 0, -2147483648) %bound) {
; CHECK-LABEL: define i32 @nneg_extended_bound(
; CHECK: affine.fast
; CHECK: %ok.affine.slow = icmp ult
; CHECK: loop:
; CHECK: br i1 true
; FULL-LABEL: define i32 @nneg_extended_bound(
; FULL: br i1 {{.*}}, label %{{.*}}, label %{{.*}}affine.slow
entry:
  %limit = sext i32 %end to i64
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i64 %i, 3
  %off = sext i32 %offset to i64
  %index = add i64 %scaled, %off
  %length = zext nneg i32 %bound to i64
  %ok = icmp ult i64 %index, %length
  br i1 %ok, label %body, label %fail, !prof !0
body:
  %narrow.index = trunc i64 %index to i32
  call void @effect(i32 %narrow.index)
  %next = add i64 %i, 1
  %again = icmp slt i64 %next, %limit
  br i1 %again, label %loop, label %exit
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i64 %i, i64 %index) ]
  ret i32 %r
exit:
  ret i32 42
}


define i32 @profiled_short(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset) {
; CHECK-LABEL: define i32 @profiled_short(
; CHECK-NOT: affine.fast
; CHECK: %ok = icmp ult
; FULL-LABEL: define i32 @profiled_short(
; FULL-NOT: affine.slow
; FULL: ret i32
entry:
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %enter = icmp slt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, 1
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail, !prof !0
body:
  call void @effect(i32 %index)
  %next = add i32 %i, -2
  %again = icmp sgt i32 %next, %end
  br i1 %again, label %loop, label %exit, !prof !7
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i32 %i, i32 %index) ]
  ret i32 %r
exit:
  ret i32 42
}


define i32 @profiled_threshold(ptr addrspace(1) noundef nonnull %a, i32 noundef %end, i32 noundef %offset) {
; CHECK-LABEL: define i32 @profiled_threshold(
; CHECK: affine.fast
; CHECK: %ok.affine.slow = icmp ult
; FULL-LABEL: define i32 @profiled_threshold(
; FULL: br i1 {{.*}}, label %{{.*}}, label %{{.*}}affine.slow
entry:
  %length = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %enter = icmp slt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, 1
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail, !prof !0
body:
  call void @effect(i32 %index)
  %next = add i32 %i, -2
  %again = icmp sgt i32 %next, %end
  br i1 %again, label %loop, label %exit, !prof !9
fail:
  %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i32 %i, i32 %index) ]
  ret i32 %r
exit:
  ret i32 42
}


!0 = !{!"branch_weights", i32 100000, i32 1}
!1 = !{}
!java-method-compilation = !{}

!7 = !{!"branch_weights", i32 7, i32 1}
!9 = !{!"branch_weights", i32 9, i32 1}
