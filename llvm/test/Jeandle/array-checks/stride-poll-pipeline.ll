; REQUIRES: aarch64-registered-target
; RUN: opt -S -verify-each -jeandle-vm-callback-log=%S/../Inputs/pre-pea-high-tier-e2e.cblog -passes='jeandle<O3>' %s | FileCheck %s --check-prefix=FINAL
; RUN: opt -S -verify-each -jeandle-vm-callback-log=%S/../Inputs/pre-pea-high-tier-e2e.cblog -passes='jeandle<O3>' -print-before=jeandle-affine-check-versioning -filter-print-funcs=nested -disable-output %s 2>&1 | FileCheck %s --check-prefix=NESTED

; The mutable bound requires retaining the loop poll. The deopt state and
; loop latch must share the IV truncation after general O3 widening.
; FINAL-LABEL: define i32 @stride(
; FINAL: [[IV:%.*]] = phi i64
; FINAL: [[NEXT:%.*]] = add nuw nsw i64 [[IV]], 3
; FINAL: [[NARROW:%.*]] = trunc nuw i64 [[NEXT]] to i32
; FINAL: br i1
; FINAL: call {{.*}}@safepoint_handler{{.*}}"deopt"(i32 [[NARROW]])
; FINAL: [[MORE:%.*]] = icmp {{slt|sgt}} i32 {{.*}}[[NARROW]]
; FINAL: br i1 [[MORE]]

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-unknown-linux-gnu"
@poll_word = external global i64
@llvm.used = appending global [2 x ptr] [ptr @jeandle.pre_barrier, ptr @jeandle.post_barrier], section "llvm.metadata"
define private hotspotcc void @jeandle.pre_barrier(ptr addrspace(1) %addr) #0 { ret void }
define private hotspotcc void @jeandle.post_barrier(ptr addrspace(1) %addr, ptr addrspace(1) %oop) #0 { ret void }
attributes #0 = { noinline "lower-phase"="1" }

declare void @safepoint_handler(ptr)
declare i64 @llvm.read_register.i64(metadata)
declare i32 @llvm.experimental.deoptimize.i32(...)
define private hotspotcc void @jeandle.safepoint_poll() #0 {
entry:
  %pending = load volatile i64, ptr @poll_word, align 8
  %needed = icmp ne i64 %pending, 0
  br i1 %needed, label %slow, label %exit
slow:
  %thread_reg = call i64 @llvm.read_register.i64(metadata !2)
  %thread = inttoptr i64 %thread_reg to ptr
  call void @safepoint_handler(ptr %thread) [ "deopt"() ]
  br label %exit
exit:
  ret void
}

define i32 @stride(ptr noundef %bound, ptr noundef %array_field) {
entry:
  %end = load atomic i32, ptr %bound unordered, align 4, !noundef !0
  %enter = icmp sgt i32 %end, 0
  br i1 %enter, label %loop, label %exit
loop:
  %i = phi i32 [ 0, %entry ], [ %next, %body ]
  %sum = phi i32 [ 0, %entry ], [ %added, %body ]
  %array = load atomic ptr, ptr %array_field unordered, align 8, !noundef !0
  %nonnull = icmp ne ptr %array, null
  br i1 %nonnull, label %check, label %null_fail
check:
  %length_addr = getelementptr inbounds i8, ptr %array, i64 12
  %length = load atomic i32, ptr %length_addr unordered, align 4, !range !1, !noundef !0
  %ok = icmp ult i32 %i, %length
  br i1 %ok, label %body, label %fail
body:
  %wide = zext i32 %i to i64
  %base = getelementptr inbounds i8, ptr %array, i64 16
  %address = getelementptr i32, ptr %base, i64 %wide
  %value = load atomic i32, ptr %address unordered, align 4, !noundef !0
  %added = add i32 %sum, %value
  %next = add i32 %i, 3
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %next) ]
  %limit = load atomic i32, ptr %bound unordered, align 4, !noundef !0
  %more = icmp slt i32 %next, %limit
  br i1 %more, label %loop, label %exit
null_fail:
  %npe = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -10) [ "deopt"(i32 %i, i32 %sum) ]
  ret i32 %npe
fail:
  %oob = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i32 %i, i32 %sum, ptr %array) ]
  ret i32 %oob
exit:
  %result = phi i32 [ 0, %entry ], [ %added, %body ]
  ret i32 %result
}

; The dynamic row stride must keep its modular i32 value through check
; versioning. Widening it earlier can hide its available outer SSA value.
; NESTED-LABEL: IR Dump Before AffineCheckVersioning
; NESTED: define i32 @nested(
; NESTED-NOT: phi i64
; NESTED: %offset{{.*}} = mul i32
; NESTED-NOT: phi i64
; NESTED: phi i32
; NESTED-NOT: phi i64
; NESTED: ret i32

define i32 @nested(ptr noundef %a, i32 noundef %rows, i32 noundef %columns, i32 noundef %stride) {
entry:
  %length_addr = getelementptr inbounds i8, ptr %a, i64 12
  %length = load atomic i32, ptr %length_addr unordered, align 4, !range !1, !noundef !0
  %base = getelementptr inbounds i8, ptr %a, i64 16
  %enter = icmp sgt i32 %rows, 0
  br i1 %enter, label %outer, label %exit
outer:
  %r = phi i32 [ 0, %entry ], [ %r_next, %outer_latch ]
  %total = phi i32 [ %length, %entry ], [ %row_sum, %outer_latch ]
  %offset = mul i32 %r, %stride
  %inner_enter = icmp sgt i32 %columns, 0
  br i1 %inner_enter, label %inner, label %outer_latch
inner:
  %j = phi i32 [ 0, %outer ], [ %j_next, %body ]
  %sum = phi i32 [ %total, %outer ], [ %added, %body ]
  %scaled = mul i32 %j, 3
  %index = add i32 %offset, %scaled
  %ok = icmp ult i32 %index, %length
  br i1 %ok, label %body, label %fail
body:
  %wide = zext i32 %index to i64
  %address = getelementptr inbounds i32, ptr %base, i64 %wide
  %value = load atomic i32, ptr %address unordered, align 4, !noundef !0
  %added = add i32 %sum, %value
  %j_next = add i32 %j, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %r, i32 %j_next, i32 %added) ]
  %more = icmp slt i32 %j_next, %columns
  br i1 %more, label %inner, label %outer_latch
outer_latch:
  %row_sum = phi i32 [ %total, %outer ], [ %added, %body ]
  %r_next = add i32 %r, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %r_next, i32 %row_sum) ]
  %again = icmp slt i32 %r_next, %rows
  br i1 %again, label %outer, label %exit
fail:
  %oob = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) [ "deopt"(i32 %r, i32 %j, i32 %sum, ptr %a) ]
  ret i32 %oob
exit:
  %result = phi i32 [ %length, %entry ], [ %row_sum, %outer_latch ]
  ret i32 %result
}
!java-method-compilation = !{}
!0 = !{}
!1 = !{i32 0, i32 -2147483648}

!2 = !{!"x28"}
