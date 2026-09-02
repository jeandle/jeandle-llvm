; RUN: opt -S -passes='function(loop-simplify,lcssa,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>)' \
; RUN:   -jeandle-loop-strip-mining-iter=1000 \
; RUN:   -jeandle-verify-safepoint-coverage=fatal < %s \
; RUN:   | FileCheck %s

; A non-unit i32 recurrence may wrap, so SCEV cannot give this loop a finite
; backedge bound. Nevertheless, every backedge traversal must pass an unsigned
; range check against a Java array length in [0, INT_MAX). The failing edge
; terminates in deoptimization. Compiled execution therefore cannot survive an
; i32 wrap: a negative wrapped index fails the unsigned comparison.

declare hotspotcc void @jeandle.safepoint_poll()
declare void @llvm.experimental.deoptimize.isVoid(...)
declare i1 @llvm.experimental.widenable.condition()

define void @mandatory_array_range_check(ptr addrspace(1) %array,
                                         i32 %start, i32 %end)
    "java-method" {
entry:
  %length.addr = getelementptr inbounds i8, ptr addrspace(1) %array, i64 12
  %length = load atomic i32, ptr addrspace(1) %length.addr unordered, align 4,
      !range !0, !invariant.load !1, !noundef !1
  br label %loop

loop:
  %iv = phi i32 [ %start, %entry ], [ %iv.next, %latch ]
  %continue = icmp slt i32 %iv, %end
  br i1 %continue, label %range.check, label %exit

range.check:
  %in.bounds = icmp ult i32 %iv, %length
  %wc = call i1 @llvm.experimental.widenable.condition()
  %guard = and i1 %in.bounds, %wc
  br i1 %guard, label %body, label %range.deopt

body:
  %array.base = getelementptr inbounds i8, ptr addrspace(1) %array, i64 16
  %array.elem = getelementptr inbounds i32, ptr addrspace(1) %array.base,
                                      i32 %iv
  store atomic i32 %iv, ptr addrspace(1) %array.elem unordered, align 4
  br label %latch

latch:
  %iv.next = add i32 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(ptr addrspace(1) %array, i32 %iv.next, i32 %end) ]
  br label %loop

range.deopt:
  call void (...) @llvm.experimental.deoptimize.isVoid(i32 -28)
      [ "deopt"(ptr addrspace(1) %array, i32 %iv, i32 %end) ]
  ret void

exit:
  ret void
}

; CHECK-LABEL: define void @mandatory_array_range_check(
; CHECK: range.check:
; CHECK: br i1 %guard, label %body, label %range.deopt
; CHECK: range.deopt:
; CHECK: @llvm.experimental.deoptimize.isVoid(i32 -28)
; CHECK-NOT: @jeandle.safepoint_poll()

; A finite-looking comparison is not enough: without a deopt failure edge the
; poll must remain.
define void @ordinary_side_exit(i32 %start, i32 %end, i32 %bound)
    "java-method" {
entry:
  br label %loop

loop:
  %iv = phi i32 [ %start, %entry ], [ %iv.next, %latch ]
  %continue = icmp slt i32 %iv, %end
  br i1 %continue, label %check, label %exit

check:
  %in.bounds = icmp ult i32 %iv, %bound
  br i1 %in.bounds, label %latch, label %exit

latch:
  %iv.next = add i32 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 %iv.next, i32 %end) ]
  br label %loop

exit:
  ret void
}

; CHECK-LABEL: define void @ordinary_side_exit(
; CHECK: call hotspotcc void @jeandle.safepoint_poll()

; Even a real range-check deopt is insufficient when another path can reach
; the latch without passing its success edge.
define void @skippable_array_range_check(ptr addrspace(1) %array,
                                         i32 %start, i32 %end,
                                         i1 %check.initial)
    "java-method" {
entry:
  %length.addr = getelementptr inbounds i8, ptr addrspace(1) %array, i64 12
  %length = load atomic i32, ptr addrspace(1) %length.addr unordered, align 4,
      !range !0, !invariant.load !1, !noundef !1
  br label %loop

loop:
  %iv = phi i32 [ %start, %entry ], [ %iv.next, %latch ]
  %check = phi i1 [ %check.initial, %entry ], [ %check.next, %latch ]
  %continue = icmp slt i32 %iv, %end
  br i1 %continue, label %dispatch, label %exit

dispatch:
  br i1 %check, label %range.check, label %body

range.check:
  %in.bounds = icmp ult i32 %iv, %length
  br i1 %in.bounds, label %body, label %range.deopt

body:
  br label %latch

latch:
  %iv.next = add i32 %iv, 2
  %check.next = xor i1 %check, true
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(ptr addrspace(1) %array, i32 %iv.next, i32 %end) ]
  br label %loop

range.deopt:
  call void (...) @llvm.experimental.deoptimize.isVoid(i32 -28)
      [ "deopt"(ptr addrspace(1) %array, i32 %iv, i32 %end) ]
  ret void

exit:
  ret void
}

; CHECK-LABEL: define void @skippable_array_range_check(
; CHECK: call hotspotcc void @jeandle.safepoint_poll()

!0 = !{i32 0, i32 2147483647}
!1 = !{}
