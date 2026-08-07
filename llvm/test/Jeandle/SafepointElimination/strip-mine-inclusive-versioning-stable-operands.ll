; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-strip-mining<inclusive-loop-versioning>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' \
; RUN:   -S < %s | FileCheck %s

; Versioning freezes the loop's limit/start so the guard and the duplicated
; tests provably read the same value. Operands already known to be neither
; undef nor poison (e.g. noundef parameters) need no freeze — freezing them
; would only add dead weight for InstCombine to clean up.

declare hotspotcc void @jeandle.safepoint_poll()

define i64 @version_stable_operands(ptr %a, i32 noundef %start, i32 noundef %limit) "java-method" {
entry:
  %nonempty = icmp sle i32 %start, %limit
  br i1 %nonempty, label %preheader, label %exit

preheader:
  br label %loop

loop:
  %iv = phi i32 [ %start, %preheader ], [ %iv.next, %loop ]
  %sum = phi i64 [ 0, %preheader ], [ %sum.next, %loop ]
  %index = sub i32 %iv, %start
  %address = getelementptr i32, ptr %a, i32 %index
  %value = load i32, ptr %address, align 4
  %wide = sext i32 %value to i64
  %sum.next = add i64 %sum, %wide
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %sum.next, i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, %limit
  br i1 %done, label %loopexit, label %loop

loopexit:
  %result = phi i64 [ %sum.next, %loop ]
  br label %exit

exit:
  %final = phi i64 [ 0, %entry ], [ %result, %loopexit ]
  ret i64 %final
}

; CHECK-LABEL: @version_stable_operands(
; CHECK-NOT:     freeze
; CHECK:         %inclusive.first_iteration = icmp sle i32 %start, %limit
; CHECK:         %inclusive.no_wrap = icmp slt i32 %limit, 2147483647
; CHECK-NOT:     freeze
; CHECK:         ret i64
