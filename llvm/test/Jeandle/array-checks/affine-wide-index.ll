; RUN: opt -passes='loop-simplify,lcssa,jeandle-affine-check-versioning' -verify-each -S %s | FileCheck %s
; RUN: opt -jeandle-affine-widen-indices=false -passes='loop-simplify,lcssa,jeandle-affine-check-versioning' -verify-each -S %s | FileCheck %s --check-prefix=SCALAR
;
; The fast guard proves the final modular index fits in a Java array. Its
; address extension can use a wide recurrence while Java/deopt uses stay narrow.

declare noundef range(i32 0, -2147483648) i32 @jeandle.arraylength(ptr noundef) nounwind willreturn memory(read)
declare void @effect(i32, i64)

define i32 @checked_extension(ptr noundef nonnull %a, i32 noundef %init, i32 noundef %end, i32 noundef %offset) {
; SCALAR-LABEL: define i32 @checked_extension(
; SCALAR: loop:
; SCALAR-NOT: phi i64
; SCALAR: br i1 true
; SCALAR: %wide = zext i32
; CHECK-LABEL: define i32 @checked_extension(
; CHECK: affine.check
; CHECK: loop.affine.slow:
; CHECK: %scaled.affine.slow = mul i32
; CHECK: %index.affine.slow = add i32
; CHECK: %ok.affine.slow = icmp ult i32
; CHECK: %wide.affine.slow = zext i32
; CHECK: loop:
; CHECK: phi i64
; CHECK: %scaled = mul i32
; CHECK: %index = add i32
; CHECK: br i1 true, label %body, label %fail
; CHECK: body:
; CHECK: call void @effect(i32 %index, i64 %{{.*}})
entry:
  %length = call i32 @jeandle.arraylength(ptr %a)
  %enter = icmp slt i32 %init, %end
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ %init, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, 5
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail
body:
  %wide = zext i32 %index to i64
  call void @effect(i32 %index, i64 %wide)
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  ret i32 -1
exit:
  ret i32 0
}

define i32 @checked_extension_reverse(ptr noundef nonnull %a, i32 noundef %init, i32 noundef %end, i32 noundef %offset) {
; SCALAR-LABEL: define i32 @checked_extension_reverse(
; SCALAR: loop:
; SCALAR-NOT: phi i64
; SCALAR: br i1 true
; SCALAR: %wide = zext i32
; CHECK-LABEL: define i32 @checked_extension_reverse(
; CHECK: affine.check
; CHECK: loop.affine.slow:
; CHECK: %scaled.affine.slow = mul i32
; CHECK: %index.affine.slow = add i32
; CHECK: %ok.affine.slow = icmp ult i32
; CHECK: %wide.affine.slow = zext i32
; CHECK: loop:
; CHECK: phi i64
; CHECK: %scaled = mul i32
; CHECK: %index = add i32
; CHECK: br i1 true, label %body, label %fail
; CHECK: body:
; CHECK: call void @effect(i32 %index, i64 %{{.*}})
entry:
  %length = call i32 @jeandle.arraylength(ptr %a)
  %enter = icmp sgt i32 %init, %end
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ %init, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, 5
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail
body:
  %wide = zext i32 %index to i64
  call void @effect(i32 %index, i64 %wide)
  %next = add i32 %i, -1
  %again = icmp sgt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  ret i32 -1
exit:
  ret i32 0
}

define i32 @checked_extension_dynamic(ptr noundef nonnull %a, i32 noundef %init, i32 noundef %end, i32 noundef %offset, i32 noundef %scale) {
; SCALAR-LABEL: define i32 @checked_extension_dynamic(
; SCALAR: loop:
; SCALAR-NOT: phi i64
; SCALAR: br i1 true
; SCALAR: %wide = zext i32
; CHECK-LABEL: define i32 @checked_extension_dynamic(
; CHECK: affine.check
; CHECK: loop.affine.slow:
; CHECK: %scaled.affine.slow = mul i32
; CHECK: %index.affine.slow = add i32
; CHECK: %ok.affine.slow = icmp ult i32
; CHECK: %wide.affine.slow = zext i32
; CHECK: loop:
; CHECK: phi i64
; CHECK: %scaled = mul i32
; CHECK: %index = add i32
; CHECK: br i1 true, label %body, label %fail
; CHECK: body:
; CHECK: call void @effect(i32 %index, i64 %{{.*}})
entry:
  %length = call i32 @jeandle.arraylength(ptr %a)
  %enter = icmp slt i32 %init, %end
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ %init, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, %scale
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail
body:
  %wide = zext i32 %index to i64
  call void @effect(i32 %index, i64 %wide)
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  ret i32 -1
exit:
  ret i32 0
}

define i32 @checked_signed_extension(ptr noundef nonnull %a, i32 noundef %init, i32 noundef %end, i32 noundef %offset) {
; SCALAR-LABEL: define i32 @checked_signed_extension(
; SCALAR: loop:
; SCALAR-NOT: phi i64
; SCALAR: br i1 true
; SCALAR: %wide = sext i32
; CHECK-LABEL: define i32 @checked_signed_extension(
; CHECK: affine.check
; CHECK: loop.affine.slow:
; CHECK: %scaled.affine.slow = mul i32
; CHECK: %index.affine.slow = add i32
; CHECK: %ok.affine.slow = icmp ult i32
; CHECK: %wide.affine.slow = sext i32
; CHECK: loop:
; CHECK: phi i64
; CHECK: %scaled = mul i32
; CHECK: %index = add i32
; CHECK: br i1 true, label %body, label %fail
; CHECK: body:
; CHECK: call void @effect(i32 %index, i64 %{{.*}})
entry:
  %length = call i32 @jeandle.arraylength(ptr %a)
  %enter = icmp slt i32 %init, %end
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %i = phi i32 [ %init, %preheader ], [ %next, %body ]
  %scaled = mul i32 %i, 5
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail
body:
  %wide = sext i32 %index to i64
  call void @effect(i32 %index, i64 %wide)
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  ret i32 -1
exit:
  ret i32 0
}

!java-method-compilation = !{}
