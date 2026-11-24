; RUN: opt -passes='loop-simplify,lcssa,jeandle-affine-check-versioning' -verify-each -S %s | FileCheck %s --check-prefixes=SIGNED,UNSIGNED,REVERSE,INDEPENDENT
;
; Keep controller extensions available to standard IndVars while preserving
; guarded widening of independent modular index recurrences.
declare noundef range(i32 0, -2147483648) i32 @jeandle.arraylength(ptr noundef) nounwind willreturn memory(read)
declare void @effect(i32, i64)

define i32 @controller_signed(ptr noundef nonnull %a, i32 noundef %from, i32 noundef %end) {
; SIGNED-LABEL: define i32 @controller_signed(
; SIGNED: affine.check
; SIGNED: loop.affine.slow:
; SIGNED: %iv.affine.slow = phi i32
; SIGNED: %ok.affine.slow = icmp ult i32
; SIGNED: %wide.affine.slow = sext i32
; SIGNED: loop:
; SIGNED-NOT: phi i64
; SIGNED: %iv = phi i32
; SIGNED-NOT: phi i64
; SIGNED: br i1 true
; SIGNED: %wide = sext i32 %iv to i64
; SIGNED: call void @effect(i32 %iv, i64 %wide)
entry:
  %length = call i32 @jeandle.arraylength(ptr %a)
  %enter = icmp slt i32 %from, %end
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i32 [ %from, %preheader ], [ %next, %body ]
  %ok = icmp ult i32 %iv, %length
  br i1 %ok, label %body, label %fail
body:
  %wide = sext i32 %iv to i64
  call void @effect(i32 %iv, i64 %wide)
  %next = add i32 %iv, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  ret i32 -1
exit:
  ret i32 0
}

define i32 @controller_unsigned(ptr noundef nonnull %a, i32 noundef %from, i32 noundef %end) {
; UNSIGNED-LABEL: define i32 @controller_unsigned(
; UNSIGNED: affine.check
; UNSIGNED: loop.affine.slow:
; UNSIGNED: %iv.affine.slow = phi i32
; UNSIGNED: %ok.affine.slow = icmp ult i32
; UNSIGNED: %wide.affine.slow = zext i32
; UNSIGNED: loop:
; UNSIGNED-NOT: phi i64
; UNSIGNED: %iv = phi i32
; UNSIGNED-NOT: phi i64
; UNSIGNED: br i1 true
; UNSIGNED: %wide = zext i32 %iv to i64
; UNSIGNED: call void @effect(i32 %iv, i64 %wide)
entry:
  %length = call i32 @jeandle.arraylength(ptr %a)
  %enter = icmp slt i32 %from, %end
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i32 [ %from, %preheader ], [ %next, %body ]
  %ok = icmp ult i32 %iv, %length
  br i1 %ok, label %body, label %fail
body:
  %wide = zext i32 %iv to i64
  call void @effect(i32 %iv, i64 %wide)
  %next = add i32 %iv, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  ret i32 -1
exit:
  ret i32 0
}

define i32 @controller_reverse(ptr noundef nonnull %a, i32 noundef %from, i32 noundef %end) {
; REVERSE-LABEL: define i32 @controller_reverse(
; REVERSE: affine.check
; REVERSE: loop.affine.slow:
; REVERSE: %iv.affine.slow = phi i32
; REVERSE: %ok.affine.slow = icmp ult i32
; REVERSE: %wide.affine.slow = sext i32
; REVERSE: loop:
; REVERSE-NOT: phi i64
; REVERSE: %iv = phi i32
; REVERSE-NOT: phi i64
; REVERSE: br i1 true
; REVERSE: %wide = sext i32 %iv to i64
; REVERSE: call void @effect(i32 %iv, i64 %wide)
entry:
  %length = call i32 @jeandle.arraylength(ptr %a)
  %enter = icmp sgt i32 %from, %end
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i32 [ %from, %preheader ], [ %next, %body ]
  %ok = icmp ult i32 %iv, %length
  br i1 %ok, label %body, label %fail
body:
  %wide = sext i32 %iv to i64
  call void @effect(i32 %iv, i64 %wide)
  %next = add i32 %iv, -1
  %again = icmp sgt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  ret i32 -1
exit:
  ret i32 0
}

define i32 @independent_index(ptr noundef nonnull %a, i32 noundef %end, i32 noundef %offset, i32 noundef %scale) {
; INDEPENDENT-LABEL: define i32 @independent_index(
; INDEPENDENT: affine.check
; INDEPENDENT: loop.affine.slow:
; INDEPENDENT: %index.affine.slow = phi i32
; INDEPENDENT: %ok.affine.slow = icmp ult i32
; INDEPENDENT: %wide.affine.slow = sext i32
; INDEPENDENT: loop:
; INDEPENDENT: phi i64
; INDEPENDENT: %iv = phi i32
; INDEPENDENT: %index = phi i32
; INDEPENDENT: br i1 true
; INDEPENDENT: call void @effect(i32 %index, i64 %{{.*}})
entry:
  %length = call i32 @jeandle.arraylength(ptr %a)
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i32 [ 0, %preheader ], [ %next, %body ]
  %index = phi i32 [ %offset, %preheader ], [ %next.index, %body ]
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail
body:
  %wide = sext i32 %index to i64
  call void @effect(i32 %index, i64 %wide)
  %next.index = add i32 %index, %scale
  %next = add i32 %iv, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  ret i32 -1
exit:
  ret i32 0
}

!java-method-compilation = !{}
