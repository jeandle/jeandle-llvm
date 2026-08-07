; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal \
; RUN:   -disable-output < %s

; A real Java array loop `for (int i = 0; i < n; i++) s += a[i]` at the
; strip-mining input point: one hot counted exit (i < n, exits to the return)
; plus two cold deopt exits -- a loop-invariant null check (!make.implicit) and
; a widenable-guarded range check -- each branching to an
; llvm.experimental.deoptimize uncommon trap. A cold exit abandons the whole
; nest, so strip mining leaves it untouched in the inner loop and wraps only the
; counted exit: the inner body goes poll-free and the back-edge poll (its deopt
; bundle holds the loop-carried .next values) relocates to the outer latch with
; those operands remapped. Shape taken from an aarch64 frontend dump.

declare hotspotcc void @jeandle.safepoint_poll()
declare i64 @llvm.experimental.deoptimize.i64(...)
declare i1 @llvm.experimental.widenable.condition()

define i64 @sum(ptr addrspace(1) %a, i32 %n, i32 %len) "java-method" {
entry:
  %isnull = icmp eq ptr addrspace(1) %a, null
  br label %header

header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %latch ]
  %s  = phi i64 [ 0, %entry ], [ %s.next, %latch ]
  %cond = icmp slt i32 %iv, %n
  br i1 %cond, label %nullcheck, label %exit

nullcheck:
  br i1 %isnull, label %npe.deopt, label %boundscheck, !make.implicit !1

boundscheck:
  %ib = icmp ult i32 %iv, %len
  %wc = call i1 @llvm.experimental.widenable.condition()
  %guard = and i1 %ib, %wc
  br i1 %guard, label %body, label %bounds.deopt

body:
  %ext = sext i32 %iv to i64
  %s.next = add i64 %s, %ext
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i32 22, i32 %n, ptr addrspace(1) %a, i64 %s.next, i32 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  %s.lcssa = phi i64 [ %s, %header ]
  ret i64 %s.lcssa

npe.deopt:
  %s.npe = phi i64 [ %s, %nullcheck ]
  %iv.npe = phi i32 [ %iv, %nullcheck ]
  %d1 = call i64 (...) @llvm.experimental.deoptimize.i64(i32 -10) [ "deopt"(i32 15, i32 %n, ptr addrspace(1) %a, i64 %s.npe, i32 %iv.npe) ]
  ret i64 %d1

bounds.deopt:
  %s.oob = phi i64 [ %s, %boundscheck ]
  %iv.oob = phi i32 [ %iv, %boundscheck ]
  %d2 = call i64 (...) @llvm.experimental.deoptimize.i64(i32 -12) [ "deopt"(i32 16, i32 %n, ptr addrspace(1) %a, i64 %s.oob, i32 %iv.oob) ]
  ret i64 %d2
}

!java-method-compilation = !{}
!1 = !{}

; This i32 loop is strip-mined: the cold deopt exits stay in the inner loop
; (untouched), the inner body goes poll-free, and the back-edge poll relocates
; to the outer latch with its deopt operands remapped to the outer recurrences.
; CHECK-LABEL: @sum(
; CHECK:       nullcheck:
; CHECK:         br i1 %isnull, label %npe.deopt, label %boundscheck
; CHECK:       boundscheck:
; CHECK:         br i1 %guard, label %body, label %bounds.deopt
; CHECK:       body:
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll

; The cold traps survive with their deopt state intact.
; CHECK:       npe.deopt:
; CHECK:         call i64 (...) @llvm.experimental.deoptimize.i64(i32 -10)
; CHECK:       bounds.deopt:
; CHECK:         call i64 (...) @llvm.experimental.deoptimize.i64(i32 -12)
; CHECK:         .outer
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}}
; CHECK:       attributes #{{[0-9]+}} = { "jeandle.strip-mined-poll" }
