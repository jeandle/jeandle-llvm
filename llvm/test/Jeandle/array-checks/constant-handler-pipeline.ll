; RUN: opt -passes='jeandle-check-optimization' -verify-each -S %s | FileCheck %s
; RUN: opt -passes='jeandle-check-optimization' -debug-pass-manager -disable-output %s 2>&1 | FileCheck %s --check-prefix=DISCOVERY
; RUN: opt -jeandle-optimize-checks=false -passes='jeandle-check-optimization' -verify-each -S %s | FileCheck %s --check-prefix=DISABLED

declare void @effect(i32)
declare i32 @handler(i32)

define i32 @constant_handler(i32 noundef %end, i32 noundef %offset, i32 noundef %scale) {
; CHECK-LABEL: define i32 @constant_handler(
; CHECK: affine.check
; CHECK: br i1 {{.*}}, label %{{.*}}, label %{{.*}}affine.slow
; CHECK: %ok.affine.slow = icmp ult
; CHECK: loop:
; CHECK-NOT: icmp ult
; CHECK: call void @effect
; CHECK: call i32 @handler
; DISABLED-LABEL: define i32 @constant_handler(
; DISABLED-NOT: affine.fast
; DISABLED: icmp ult
; DISABLED: call i32 @handler
entry:
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %next, %body ]
  %scaled = mul i32 %i, %scale
  %index = add i32 %scaled, %offset
  %ok = icmp ult i32 %index, 1024
  br i1 %ok, label %body, label %fail
body:
  call void @effect(i32 %index)
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %end
  br i1 %again, label %loop, label %exit
fail:
  %result = call i32 @handler(i32 %index)
  ret i32 %result
exit:
  ret i32 42
}

; DISCOVERY: Running pass: CheckOptimization on unchecked
; DISCOVERY-NOT: Running pass: EarlyCSEPass
; DISCOVERY-NOT: Running pass: LoopSimplifyPass
; DISCOVERY: Running pass: VerifierPass
define i64 @unchecked(i32 noundef %end, i64 noundef %seed) {
entry:
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %next, %body ]
  %sum = phi i64 [ %seed, %entry ], [ %added, %body ]
  %again = icmp slt i32 %i, %end
  br i1 %again, label %body, label %exit
body:
  call void @effect(i32 %i)
  %added = add i64 %sum, 1
  %next = add i32 %i, 2
  br label %loop
exit:
  ret i64 %sum
}

!java-method-compilation = !{}
