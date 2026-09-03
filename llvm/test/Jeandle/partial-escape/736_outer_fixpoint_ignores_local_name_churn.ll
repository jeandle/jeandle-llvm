; RUN: opt -S -passes='partial-escape-iterative' -jeandle-pea-iterations=4 \
; RUN:   -jeandle-dump-pea-ir=name_churn %s 2>&1 \
; RUN:   | grep -E 'PEA-DUMP after|PEA-SUMMARY' | FileCheck %s

; SimplifyCFG folds the trivial dedicated exit and LoopSimplify recreates it.
; Its numeric suffix changes each round, but the canonical IR is identical and
; an idle PEA transform must reach a fixpoint instead of exhausting the cap.

define i32 @name_churn(i1 %skip, i32 %limit) "java-method" {
entry:
  br i1 %skip, label %exit, label %loop

loop:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop ]
  %iv.next = add nuw nsw i32 %iv, 1
  %done = icmp eq i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop

exit:
  %result = phi i32 [ -1, %entry ], [ %iv.next, %loop ]
  ret i32 %result
}

!java-method-compilation = !{}

; CHECK:      ;; PEA-DUMP after iter=0 function name_churn transform_idle=1
; CHECK:      ;; PEA-DUMP after iter=1 function name_churn transform_idle=1
; CHECK:      ;; PEA-SUMMARY function name_churn rounds=2 stop=fixpoint
