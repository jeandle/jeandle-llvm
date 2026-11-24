; RUN: opt -passes='jeandle-check-optimization,instcombine,simplifycfg' -verify-each -S %s | FileCheck %s
; RUN: opt -passes='instcombine,simplifycfg' -verify-each -S %s | FileCheck %s --check-prefix=UPSTREAM

declare i32 @llvm.smin.i32(i32, i32)
declare i32 @llvm.smax.i32(i32, i32)
declare void @effect(i32)
define i1 @positive_range(i32 noundef %x, i32 noundef range(i32 1, -2147483648) %length) {
; UPSTREAM-LABEL: define i1 @positive_range(
; UPSTREAM: icmp ult
; CHECK-LABEL: define i1 @positive_range(
; CHECK-NOT: icmp ult
; CHECK: ret i1 true
entry:
  br label %body
body:
  %last = add i32 %length, -1
  %lo = call i32 @llvm.smax.i32(i32 %x, i32 0)
  %index = call i32 @llvm.smin.i32(i32 %lo, i32 %last)
  %ok = icmp ult i32 %index, %length
  ret i1 %ok
exit:
  ret i1 false
}
define i1 @dominating_positive(i32 noundef %x, i32 noundef range(i32 0, -2147483648) %length) {
; CHECK-LABEL: define i1 @dominating_positive(
; CHECK-NOT: icmp ult
; CHECK: %[[POSITIVE:.*]] = icmp ne i32 %length, 0
; CHECK-NEXT: ret i1 %[[POSITIVE]]
entry:
  %positive = icmp sgt i32 %length, 0
  br i1 %positive, label %body, label %exit
body:
  %last = add i32 %length, -1
  %lo = call i32 @llvm.smax.i32(i32 %x, i32 0)
  %index = call i32 @llvm.smin.i32(i32 %lo, i32 %last)
  %ok = icmp ult i32 %index, %length
  ret i1 %ok
exit:
  ret i1 false
}
define i1 @zero_possible(i32 noundef %x, i32 noundef range(i32 0, -2147483648) %length) {
; CHECK-LABEL: define i1 @zero_possible(
; CHECK: icmp ult
entry:
  br label %body
body:
  %last = add i32 %length, -1
  %lo = call i32 @llvm.smax.i32(i32 %x, i32 0)
  %index = call i32 @llvm.smin.i32(i32 %lo, i32 %last)
  %ok = icmp ult i32 %index, %length
  ret i1 %ok
exit:
  ret i1 false
}
define i1 @arbitrary_length(i32 noundef %x, i32 noundef %length) {
; CHECK-LABEL: define i1 @arbitrary_length(
; CHECK: icmp ult
entry:
  br label %body
body:
  %last = add i32 %length, -1
  %lo = call i32 @llvm.smax.i32(i32 %x, i32 0)
  %index = call i32 @llvm.smin.i32(i32 %lo, i32 %last)
  %ok = icmp ult i32 %index, %length
  ret i1 %ok
exit:
  ret i1 false
}
define i32 @loop_modular(i32 noundef %end, i32 noundef %offset, i32 noundef range(i32 1, -2147483648) %length) {
; CHECK-LABEL: define i32 @loop_modular(
; CHECK-NOT: icmp ult
; CHECK: call void @effect
entry:
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  %last = add i32 %length, -1
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %raw = add i32 %i, %offset

  %lo = call i32 @llvm.smax.i32(i32 %raw, i32 0)
  %index = call i32 @llvm.smin.i32(i32 %lo, i32 %last)
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail
body:
  call void @effect(i32 %index)
  %next = add i32 %i, 1
  %more = icmp slt i32 %next, %end
  br i1 %more, label %loop, label %exit
fail:
  ret i32 -1
exit:
  ret i32 0
}
define i32 @loop_frozen(i32 noundef %end, i32 noundef %offset, i32 noundef range(i32 1, -2147483648) %length) {
; CHECK-LABEL: define i32 @loop_frozen(
; CHECK-NOT: icmp ult
; CHECK: call void @effect
entry:
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  %last = add i32 %length, -1
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %next, %body ]
  %raw = add i32 %i, %offset
  %defined = freeze i32 %raw
  %lo = call i32 @llvm.smax.i32(i32 %defined, i32 0)
  %index = call i32 @llvm.smin.i32(i32 %lo, i32 %last)
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail
body:
  call void @effect(i32 %index)
  %next = add i32 %i, 1
  %more = icmp slt i32 %next, %end
  br i1 %more, label %loop, label %exit
fail:
  ret i32 -1
exit:
  ret i32 0
}

define i1 @upper_equal_length(i32 noundef %x, i32 noundef range(i32 1, -2147483648) %length) {
; CHECK-LABEL: define i1 @upper_equal_length(
; CHECK: icmp {{[su]lt}}
entry:
  br label %body
body:
  %last = add i32 %length, 0
  %lo = call i32 @llvm.smax.i32(i32 %x, i32 0)
  %index = call i32 @llvm.smin.i32(i32 %lo, i32 %last)
  %ok = icmp ult i32 %index, %length
  ret i1 %ok
exit:
  ret i1 false
}

define i1 @lower_negative(i32 noundef %x, i32 noundef range(i32 1, -2147483648) %length) {
; CHECK-LABEL: define i1 @lower_negative(
; CHECK: icmp ult
entry:
  br label %body
body:
  %last = add i32 %length, -1
  %lo = call i32 @llvm.smax.i32(i32 %x, i32 -1)
  %index = call i32 @llvm.smin.i32(i32 %lo, i32 %last)
  %ok = icmp ult i32 %index, %length
  ret i1 %ok
exit:
  ret i1 false
}

define i1 @swapped_i64(i64 noundef %x, i64 noundef range(i64 1, -9223372036854775808) %length) {
; CHECK-LABEL: define i1 @swapped_i64(
; CHECK: ret i1 true
  %last = sub i64 %length, 1
  %lo = call i64 @llvm.smax.i64(i64 %x, i64 0)
  %index = call i64 @llvm.smin.i64(i64 %last, i64 %lo)
  %ok = icmp ugt i64 %length, %index
  ret i1 %ok
}

define i1 @failure_i8(i8 noundef %x, i8 noundef range(i8 1, -128) %length) {
; CHECK-LABEL: define i1 @failure_i8(
; CHECK: ret i1 false
  %last = add i8 -1, %length
  %lo = call i8 @llvm.smax.i8(i8 %x, i8 0)
  %index = call i8 @llvm.smin.i8(i8 %lo, i8 %last)
  %fail = icmp uge i8 %index, %length
  ret i1 %fail
}

define i1 @swapped_failure(i32 noundef range(i32 0, -2147483648) %lo, i32 noundef range(i32 1, -2147483648) %length) {
; CHECK-LABEL: define i1 @swapped_failure(
; CHECK: ret i1 false
  %last = add i32 %length, -1
  %index = call i32 @llvm.smin.i32(i32 %lo, i32 %last)
  %fail = icmp ule i32 %length, %index
  ret i1 %fail
}

define i1 @different_upper(i32 noundef %x, i32 noundef range(i32 1, -2147483648) %length, i32 noundef range(i32 1, -2147483648) %other) {
; CHECK-LABEL: define i1 @different_upper(
; CHECK: icmp ult
  %last = add i32 %other, -1
  %lo = call i32 @llvm.smax.i32(i32 %x, i32 0)
  %index = call i32 @llvm.smin.i32(i32 %lo, i32 %last)
  %ok = icmp ult i32 %index, %length
  ret i1 %ok
}

declare i64 @llvm.smin.i64(i64, i64)
declare i64 @llvm.smax.i64(i64, i64)
declare i8 @llvm.smin.i8(i8, i8)
declare i8 @llvm.smax.i8(i8, i8)

!java-method-compilation = !{}
