; RUN: opt < %s -passes=reassociate -S | FileCheck %s --check-prefix=ON
; RUN: opt < %s -passes=reassociate -reassociate-loop-carried-recurrence=false -S | FileCheck %s --check-prefix=OFF
; RUN: opt < %s -passes=reassociate -reassociate-loop-carried-recurrence-slice-limit=1 -S | FileCheck %s --check-prefix=OFF
; RUN: opt < %s -passes=reassociate -reassociate-loop-carried-recurrence-slice-limit=7 -S | FileCheck %s --check-prefix=OFF

; The hidden -reassociate-loop-carried-recurrence flag (default on) gates whether
; a loop-carried recurrence phi is placed at the outermost operand. With it off,
; ordering falls back to the legacy rank-only behavior (phi sunk into the inner
; add). Same recurrence as loop-carried-phi.ll's first case.
; The limit RUNs exhaust the classifier's shared def-use edge budget at
; different stages -- limit=1 inside the root slice, limit=7 midway through the
; recurrence slice (whose partial set must be discarded) -- and each must fall
; back to the same legacy order, never classify from a partial slice.

define i32 @flag(i32 %n, ptr %arr) {
; ON-LABEL: @flag
; ON:         %s = phi i32 [ 0, %entry ], [ [[ADD2:%.*]], %loop ]
; ON:         [[M:%.*]] = mul i32 %v, 7
; ON:         [[R:%.*]] = lshr i32 %v, 2
; ON:         [[ADD1:%.*]] = add i32 [[M]], [[R]]
; ON:         [[ADD2]] = add i32 [[ADD1]], %s
;
; OFF-LABEL: @flag
; OFF:        %s = phi i32 [ 0, %entry ], [ [[ADD2:%.*]], %loop ]
; OFF:        [[M:%.*]] = mul i32 %v, 7
; OFF:        [[R:%.*]] = lshr i32 %v, 2
; OFF:        [[ADD1:%.*]] = add i32 [[R]], %s
; OFF:        [[ADD2]] = add i32 [[ADD1]], [[M]]
entry:
  br label %loop

loop:
  %s = phi i32 [ 0, %entry ], [ %add2, %loop ]
  %i = phi i32 [ 0, %entry ], [ %i.next, %loop ]
  %p = getelementptr i32, ptr %arr, i32 %i
  %v = load i32, ptr %p, align 4
  %m = mul i32 %v, 7
  %r = lshr i32 %v, 2
  %add1 = add i32 %m, %r
  %add2 = add i32 %add1, %s
  %i.next = add i32 %i, 1
  %cmp = icmp slt i32 %i.next, %n
  br i1 %cmp, label %loop, label %exit

exit:
  ret i32 %add2
}
