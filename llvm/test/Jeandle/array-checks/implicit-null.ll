; RUN: opt -passes='jeandle-check-optimization' -verify-each -S %s -o %t
; RUN: FileCheck %s < %t
; RUN: llc -mtriple=x86_64-unknown-linux-gnu -enable-implicit-null-checks %t -o - | FileCheck %s --check-prefix=ASM
; REQUIRES: x86-registered-target

target triple = "x86_64-unknown-linux-gnu"

declare i32 @jeandle.arraylength(ptr addrspace(1)) nounwind memory(read)
declare i32 @hot_handler() nounwind

define i32 @hot_null(ptr addrspace(1) noundef %x) {
; CHECK-LABEL: define i32 @hot_null(
; CHECK: br i1 {{.*}}, label %{{.*}}, label %{{.*}}, !make.implicit
; CHECK: }
; ASM-LABEL: hot_null:
; ASM: movl {{.*}} # on-fault:
; ASM: .llvm_faultmaps

entry:
  %ok = icmp ne ptr addrspace(1) %x, null
  br i1 %ok, label %not_null, label %is_null, !make.implicit !0
not_null:
  %v = load atomic i32, ptr addrspace(1) %x unordered, align 4
  %len = call i32 @jeandle.arraylength(ptr addrspace(1) %x)
  %r = add i32 %v, %len
  ret i32 %r
is_null:
  %e = call i32 @hot_handler()
  ret i32 %e
}
; A non-pointer condition cannot carry implicit-null-check eligibility.
define i32 @stale(i32 noundef %x) {
; CHECK-LABEL: define i32 @stale(
; CHECK: br i1 {{.*}}, label %{{.*}}, label %{{.*}}{{$}}
; CHECK: }
  %ok = icmp ne i32 %x, 0
  br i1 %ok, label %yes, label %no, !make.implicit !0
yes:
  %d = call i32 (...) @llvm.experimental.deoptimize.i32() ["deopt"()]
  ret i32 %d
no:
  ret i32 0
}
declare i32 @llvm.experimental.deoptimize.i32(...)
!0 = !{}
!java-method-compilation = !{}
