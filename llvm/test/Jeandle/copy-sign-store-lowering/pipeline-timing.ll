; RUN: opt -passes='function(copy-sign-store-lowering,loop-simplify,lcssa),default<O3>' -mtriple=x86_64-unknown-linux-gnu -verify-each -S < %s | FileCheck %s --check-prefix=EARLY
; RUN: opt -passes='function(loop-simplify,lcssa,copy-sign-store-lowering),default<O3>' -mtriple=x86_64-unknown-linux-gnu -verify-each -S < %s | FileCheck %s --check-prefix=LATE
; RUN: opt -passes='loop-simplify,lcssa' -verify-each -S < %s | FileCheck %s --check-prefix=LCSSA

; Loop canonicalization inserts a result PHI for the exit's deopt payload.
; Lower the direct store/deopt uses first; the matcher does not follow PHIs.
declare float @llvm.copysign.f32(float, float)
declare double @llvm.copysign.f64(double, double)
declare void @safepoint()

define void @loop_store_deopt_f32(ptr %mp, ptr %sp, ptr %p, i64 %n) {
; EARLY-LABEL: @loop_store_deopt_f32(
; EARLY: load atomic i32,
; EARLY: load atomic i32,
; EARLY: and i32 {{.*}}, 2147483647
; EARLY: and i32 {{.*}}, -2147483648
; EARLY: store atomic i32
; EARLY: call void @safepoint() [ "deopt"(float %{{.*}}) ]
; LATE-LABEL: @loop_store_deopt_f32(
; LATE: %[[R32:.*]] = {{(tail )?}}call float @llvm.copysign.f32(
; LATE: store atomic float %[[R32]],
; LATE: call void @safepoint() [ "deopt"(float %{{.*}}) ]
; LCSSA-LABEL: @loop_store_deopt_f32(
; LCSSA: %r = call float @llvm.copysign.f32(
; LCSSA: store atomic float %r,
; LCSSA: %[[EXIT32:.*]] = phi float [ %r, %loop ]
; LCSSA-NEXT: call void @safepoint() [ "deopt"(float %[[EXIT32]]) ]
entry:
  br label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %maddr = getelementptr float, ptr %mp, i64 %i
  %saddr = getelementptr float, ptr %sp, i64 %i
  %out = getelementptr float, ptr %p, i64 %i
  %m = load atomic float, ptr %maddr unordered, align 4
  %s = load atomic float, ptr %saddr unordered, align 4
  %r = call float @llvm.copysign.f32(float %m, float %s)
  store atomic float %r, ptr %out unordered, align 4
  %next = add i64 %i, 1
  %more = icmp ult i64 %next, %n
  br i1 %more, label %loop, label %exit

exit:
  call void @safepoint() [ "deopt"(float %r) ]
  ret void
}

define void @loop_store_deopt_f64(ptr %mp, ptr %sp, ptr %p, i64 %n) {
; EARLY-LABEL: @loop_store_deopt_f64(
; EARLY: load atomic i64,
; EARLY: load atomic i64,
; EARLY: and i64 {{.*}}, 9223372036854775807
; EARLY: and i64 {{.*}}, -9223372036854775808
; EARLY: store atomic i64
; EARLY: call void @safepoint() [ "deopt"(double %{{.*}}) ]
; LATE-LABEL: @loop_store_deopt_f64(
; LATE: %[[R64:.*]] = {{(tail )?}}call double @llvm.copysign.f64(
; LATE: store atomic double %[[R64]],
; LATE: call void @safepoint() [ "deopt"(double %{{.*}}) ]
; LCSSA-LABEL: @loop_store_deopt_f64(
; LCSSA: %r = call double @llvm.copysign.f64(
; LCSSA: store atomic double %r,
; LCSSA: %[[EXIT64:.*]] = phi double [ %r, %loop ]
; LCSSA-NEXT: call void @safepoint() [ "deopt"(double %[[EXIT64]]) ]
entry:
  br label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %maddr = getelementptr double, ptr %mp, i64 %i
  %saddr = getelementptr double, ptr %sp, i64 %i
  %out = getelementptr double, ptr %p, i64 %i
  %m = load atomic double, ptr %maddr unordered, align 8
  %s = load atomic double, ptr %saddr unordered, align 8
  %r = call double @llvm.copysign.f64(double %m, double %s)
  store atomic double %r, ptr %out unordered, align 8
  %next = add i64 %i, 1
  %more = icmp ult i64 %next, %n
  br i1 %more, label %loop, label %exit

exit:
  call void @safepoint() [ "deopt"(double %r) ]
  ret void
}

!java-method-compilation = !{!0}
!0 = !{}
