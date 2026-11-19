; RUN: opt -passes='jeandle-check-optimization' -verify-each -S %s | FileCheck %s

; A deopt exit alone does not authorize the cost of repeated null faults.
define i32 @unlicensed_deopt(ptr addrspace(1) noundef %array) {
; CHECK-LABEL: define i32 @unlicensed_deopt(
; CHECK: br i1 {{.*}}, label %failure, label %nonnull{{$}}
; CHECK: }
entry:
  %isnull = icmp eq ptr addrspace(1) %array, null
  br i1 %isnull, label %failure, label %nonnull
nonnull:
  %value = load atomic i32, ptr addrspace(1) %array unordered, align 4
  ret i32 %value
failure:
  %result = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) [ "deopt"() ]
  ret i32 %result
}

define i32 @action_none(ptr addrspace(1) noundef %array) {
; CHECK-LABEL: define i32 @action_none(
; CHECK: br i1 {{.*}}, label %failure, label %nonnull{{$}}
; CHECK: }
entry:
  %isnull = icmp eq ptr addrspace(1) %array, null
  br i1 %isnull, label %failure, label %nonnull
nonnull:
  %value = load atomic i32, ptr addrspace(1) %array unordered, align 4
  ret i32 %value
failure:
  %result = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -9) [ "deopt"() ]
  ret i32 %result
}

; Positive permission lives on the deopt when the branch is widened/rebuilt.
define i32 @licensed_deopt(ptr addrspace(1) noundef %array) {
; CHECK-LABEL: define i32 @licensed_deopt(
; CHECK: br i1 {{.*}}, label %failure, label %nonnull, !make.implicit
; CHECK: }
entry:
  %isnull = icmp eq ptr addrspace(1) %array, null
  br i1 %isnull, label %failure, label %nonnull
nonnull:
  %value = load atomic i32, ptr addrspace(1) %array unordered, align 4
  ret i32 %value
failure:
  %result = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) #0 [ "deopt"() ]
  ret i32 %result
}

define i32 @licensed_widened(ptr addrspace(1) noundef %array) {
; CHECK-LABEL: define i32 @licensed_widened(
; CHECK: br i1 {{.*}}, label %failure, label %nonnull, !make.implicit
; CHECK: }
entry:
  %ok = icmp ne ptr addrspace(1) %array, null
  %permission = call i1 @llvm.experimental.widenable.condition()
  %condition = and i1 %ok, %permission
  br i1 %condition, label %nonnull, label %failure
nonnull:
  %value = load atomic i32, ptr addrspace(1) %array unordered, align 4
  ret i32 %value
failure:
  %request = select i1 %ok, i32 -147, i32 -10
  %result = call i32 (...) @llvm.experimental.deoptimize.i32(i32 %request) #0 [ "deopt"() ]
  ret i32 %result
}

; Existing explicit permission remains valid through cleanup.
define i32 @existing_permission(ptr addrspace(1) noundef %array) {
; CHECK-LABEL: define i32 @existing_permission(
; CHECK: br i1 {{.*}}, label %failure, label %nonnull, !make.implicit
; CHECK: }
entry:
  %isnull = icmp eq ptr addrspace(1) %array, null
  br i1 %isnull, label %failure, label %nonnull, !make.implicit !0
nonnull:
  %value = load atomic i32, ptr addrspace(1) %array unordered, align 4
  ret i32 %value
failure:
  %result = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) [ "deopt"() ]
  ret i32 %result
}

declare i32 @llvm.experimental.deoptimize.i32(...)
declare i1 @llvm.experimental.widenable.condition()
attributes #0 = { "jeandle-implicit-null-check" }
!0 = !{}
!java-method-compilation = !{}
