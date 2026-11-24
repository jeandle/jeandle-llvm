; RUN: opt -passes='loop-simplify,lcssa,jeandle-affine-check-versioning' -verify-each -S %s | FileCheck %s

declare void @effect(i64)

define i64 @bounded_wide_inputs(i32 noundef %end, i32 noundef %offset, i32 noundef %scale) {
; CHECK-LABEL: define i64 @bounded_wide_inputs(
; CHECK: loop.affine.check:
; CHECK-NOT: i128
; CHECK-NOT: affine.low
; CHECK-NOT: affine.high
; CHECK: icmp ult i64 {{.*}}, 1024
; CHECK-NOT: i128
; CHECK-NOT: affine.low
; CHECK-NOT: affine.high
; CHECK: icmp ult i64 {{.*}}, 1024
; CHECK-NOT: i128
; CHECK: br i1 {{.*}}, label %loop.affine.fast, label %{{.*}}affine.slow
; CHECK: %ok.affine.slow = icmp ult i64
; CHECK: loop:
; CHECK: br i1 true
entry:
  %limit = zext i32 %end to i64
  %first = sext i32 %offset to i64
  %step = sext i32 %scale to i64
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %body ]
  %scaled = mul i64 %i, %step
  %index = add i64 %scaled, %first
  %ok = icmp ult i64 %index, 1024
  br i1 %ok, label %body, label %fail
body:
  call void @effect(i64 %index)
  %next = add i64 %i, 1
  %again = icmp ult i64 %next, %limit
  br i1 %again, label %loop, label %exit
fail:
  ret i64 -1
exit:
  ret i64 42
}

define i64 @unbounded_index(i32 noundef %end, i64 noundef %offset, i64 noundef %scale) {
; CHECK-LABEL: define i64 @unbounded_index(
; CHECK: loop.affine.check:
; CHECK: mul i128
; CHECK: icmp ult i128 {{.*}}, 1024
; CHECK: icmp ult i128 {{.*}}, 1024
; CHECK: br i1 {{.*}}, label %loop.affine.fast, label %{{.*}}affine.slow
entry:
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %next, %body ]
  %index = phi i64 [ %offset, %entry ], [ %index.next, %body ]
  %ok = icmp ult i64 %index, 1024
  br i1 %ok, label %body, label %fail
body:
  call void @effect(i64 %index)
  %index.next = add i64 %index, %scale
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  ret i64 -1
exit:
  ret i64 42
}

define i64 @shared_endpoints(i32 noundef %end, i32 noundef %offset, i32 noundef %scale) {
; CHECK-LABEL: define i64 @shared_endpoints(
; CHECK: loop.affine.check:
; CHECK: icmp ult i64 {{.*}}, 1024
; CHECK: icmp ult i64 {{.*}}, 1024
; CHECK-NOT: icmp ult i64
; CHECK: br i1 {{.*}}, label %loop.affine.fast, label %{{.*}}affine.slow
; CHECK: %ok.affine.slow = icmp ult
; CHECK: %second.ok.affine.slow = icmp ugt
; CHECK: loop:
; CHECK: br i1 true
; CHECK: second:
; CHECK: br i1 true
entry:
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %next, %body ]
  %index = phi i32 [ %offset, %entry ], [ %index.next, %body ]
  %ok = icmp ult i32 %index, 1024
  br i1 %ok, label %second, label %fail
second:
  call void @effect(i64 1)
  %second.ok = icmp ugt i32 1024, %index
  br i1 %second.ok, label %body, label %fail
body:
  %index.next = add i32 %index, %scale
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  ret i64 -1
exit:
  ret i64 42
}

define i64 @narrow_inputs(i32 noundef range(i32 1, 65) %end, i32 noundef range(i32 0, 1024) %offset, i32 noundef range(i32 -8, 9) %scale) {
; CHECK-LABEL: define i64 @narrow_inputs(
; CHECK: loop.affine.check:
; CHECK-NOT: i64
; CHECK-NOT: i128
; CHECK: mul i32
; CHECK: icmp ult i32 {{.*}}, 1024
; CHECK: icmp ult i32 {{.*}}, 1024
; CHECK: br i1 {{.*}}, label %loop.affine.fast, label %{{.*}}affine.slow
entry:
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %next, %body ]
  %index = phi i32 [ %offset, %entry ], [ %index.next, %body ]
  %ok = icmp ult i32 %index, 1024
  br i1 %ok, label %body, label %fail
body:
  call void @effect(i64 1)
  %index.next = add i32 %index, %scale
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  ret i64 -1
exit:
  ret i64 42
}

define i64 @unsigned_i64_wrap(i64 noundef %start, i64 noundef %end) {
; CHECK-LABEL: define i64 @unsigned_i64_wrap(
; CHECK: loop.affine.check:
; CHECK: icmp sle i128 {{.*}}, 18446744073709551615
; CHECK: br i1 {{.*}}, label %loop.affine.fast, label %{{.*}}affine.slow
entry:
  br label %loop
loop:
  %i = phi i64 [ %start, %entry ], [ %next, %body ]
  %index = phi i32 [ 0, %entry ], [ %index.next, %body ]
  %ok = icmp ult i32 %index, 1024
  br i1 %ok, label %body, label %fail
body:
  call void @effect(i64 1)
  %index.next = add i32 %index, 1
  %next = add i64 %i, 1
  %again = icmp ule i64 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  ret i64 -1
exit:
  ret i64 42
}

!java-method-compilation = !{}
