; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-strip-mining<inclusive-loop-versioning>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' \
; RUN:   -jeandle-enable-inclusive-loop-versioning -verify-each -S < %s | FileCheck %s
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,early-cse,instcombine,simplifycfg,loop-simplify,lcssa,safepoint-strip-mining<inclusive-loop-versioning>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' \
; RUN:   -jeandle-enable-inclusive-loop-versioning -verify-each -S < %s | FileCheck %s --check-prefix=PIPELINE
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-strip-mining<inclusive-loop-versioning>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-enable-inclusive-loop-versioning -jeandle-verify-safepoint-coverage=fatal \
; RUN:   -verify-each -disable-output < %s

; Minimized from the frontend shape for:
;
;   for (int i = start; i >= limit; i--) sum += a[start - i];
;
; A limit above INT_MIN permits a bounded strip-mined fast path. INT_MIN must
; retain the original polling scalar loop because the final decrement wraps.

declare hotspotcc void @jeandle.safepoint_poll()

define i64 @runtime_inclusive_decreasing_i32(ptr %a, i32 %start, i32 %limit) "java-method" {
entry:
  %nonempty = icmp sge i32 %start, %limit
  br i1 %nonempty, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i32 [ %start, %preheader ], [ %iv.next, %loop ]
  %sum = phi i64 [ 0, %preheader ], [ %sum.next, %loop ]
  %index = sub i32 %start, %iv
  %address = getelementptr i32, ptr %a, i32 %index
  %value = load i32, ptr %address, align 4
  %wide = sext i32 %value to i64
  %sum.next = add i64 %sum, %wide
  %iv.next = add i32 %iv, -1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %sum.next, i32 %iv.next) ]
  %done = icmp slt i32 %iv.next, %limit
  br i1 %done, label %loopexit, label %loop
loopexit:
  %result = phi i64 [ %sum.next, %loop ]
  br label %exit
exit:
  %final = phi i64 [ 0, %entry ], [ %result, %loopexit ]
  ret i64 %final
}

; A latch-tested do/while shape has no dominating first-iteration guard. When
; start < limit, versioning must select the original slow loop so its one
; iteration is preserved instead of turning it into an empty fast loop.
define i32 @runtime_inclusive_decreasing_unguarded_latch_i32(i32 %start,
                                                              i32 %limit) "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i32 [ %start, %entry ], [ %iv.next, %loop ]
  %count = phi i32 [ 0, %entry ], [ %count.next, %loop ]
  %count.next = add i32 %count, 1
  %iv.next = add i32 %iv, -1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %count.next, i32 %iv.next) ]
  %done = icmp slt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %count.next, %loop ]
  ret i32 %result
}

; The real frontend enters through a header test. Loop rotation and CFG cleanup
; may change this shape before versioning, so both direct and pipeline forms are
; permanent fixtures.
define i64 @runtime_inclusive_decreasing_header_i32(ptr %a, i32 %start,
                                                     i32 %limit) "java-method" {
entry:
  br label %header
header:
  %iv = phi i32 [ %start, %entry ], [ %iv.next, %body ]
  %sum = phi i64 [ 0, %entry ], [ %sum.next, %body ]
  %continue = icmp sge i32 %iv, %limit
  br i1 %continue, label %body, label %exit
body:
  %index = sub i32 %start, %iv
  %address = getelementptr i32, ptr %a, i32 %index
  %value = load i32, ptr %address, align 4
  %wide = sext i32 %value to i64
  %sum.next = add i64 %sum, %wide
  %iv.next = add i32 %iv, -1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %sum.next, i32 %iv.next) ]
  br label %header
exit:
  %result = phi i64 [ %sum, %header ]
  ret i64 %result
}

; These legal shapes remain outside this enhancement and retain their polls.
define void @runtime_inclusive_decreasing_unsigned_i32(i32 %start,
                                                        i32 %limit) "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i32 [ %start, %entry ], [ %iv.next, %loop ]
  %iv.next = add i32 %iv, -1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp ult i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

define void @runtime_inclusive_decreasing_i64(i64 %start, i64 %limit) "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i64 [ %start, %entry ], [ %iv.next, %loop ]
  %iv.next = add i64 %iv, -1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  %done = icmp slt i64 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

define void @runtime_inclusive_decreasing_step2_i32(i32 %start, i32 %limit) "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i32 [ %start, %entry ], [ %iv.next, %loop ]
  %iv.next = add i32 %iv, -2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp slt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

define void @runtime_inclusive_decreasing_current_phi_deopt(i32 %start,
                                                             i32 %limit) "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i32 [ %start, %entry ], [ %iv.next, %loop ]
  %iv.next = add i32 %iv, -1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv) ]
  %done = icmp slt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @runtime_inclusive_decreasing_i32(
; CHECK:       %inclusive.limit.fr = freeze i32 %limit
; CHECK:       %inclusive.start.fr = freeze i32 %start
; CHECK:       %inclusive.first_iteration = icmp sge i32 %inclusive.start.fr, %inclusive.limit.fr
; CHECK:       %inclusive.no_wrap = icmp sgt i32 %inclusive.limit.fr, -2147483648
; CHECK-DAG:   loop.inclusive.slow:
; CHECK-DAG:   call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %sum.next.inclusive.slow, i32 %iv.next.inclusive.slow) ]
; CHECK-DAG:   loop.outer:
; CHECK-DAG:   %outer.batch.dist = sub nsw i64
; CHECK-DAG:   call i64 @llvm.smin.i64
; CHECK-DAG:   %outer.inner.limit = sub nsw i32 %outer.iv, %outer.batch.chunk
; CHECK-DAG:   loop.outer.latch:
; CHECK-DAG:   call hotspotcc void @jeandle.safepoint_poll()

; CHECK-LABEL: @runtime_inclusive_decreasing_unguarded_latch_i32(
; CHECK:       %inclusive.first_iteration = icmp sge i32 %inclusive.start.fr, %inclusive.limit.fr
; CHECK-NEXT:  br i1 %inclusive.first_iteration, label %loop.inclusive.no_wrap.check, label %loop.inclusive.fast.ph.inclusive.slow
; CHECK:       %inclusive.no_wrap = icmp sgt i32 %inclusive.limit.fr, -2147483648
; CHECK-DAG:   loop.inclusive.slow:
; CHECK-DAG:   call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %count.next.inclusive.slow, i32 %iv.next.inclusive.slow) ]
; CHECK-DAG:   loop.outer:

; CHECK-LABEL: @runtime_inclusive_decreasing_header_i32(
; CHECK:       %inclusive.first_iteration = icmp sge i32 %inclusive.start.fr, %inclusive.limit.fr
; CHECK:       %inclusive.no_wrap = icmp sgt i32 %inclusive.limit.fr, -2147483648
; CHECK-DAG:   body.inclusive.slow:
; CHECK-DAG:   body.outer:
; CHECK-DAG:   body.outer.latch:

; CHECK-LABEL: @runtime_inclusive_decreasing_unsigned_i32(
; CHECK-NOT:   inclusive.no_wrap
; CHECK-NOT:   inclusive.slow
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()

; CHECK-LABEL: @runtime_inclusive_decreasing_i64(
; CHECK-NOT:   inclusive.no_wrap
; CHECK-NOT:   inclusive.slow
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()

; CHECK-LABEL: @runtime_inclusive_decreasing_step2_i32(
; CHECK:       %inclusive.no_wrap = icmp sgt i32 %inclusive.limit.fr, -2147483647
; CHECK-DAG:   loop.inclusive.slow:
; CHECK-DAG:   loop.outer:
; CHECK-DAG:   loop.outer.latch:

; CHECK-LABEL: @runtime_inclusive_decreasing_current_phi_deopt(
; CHECK-NOT:   inclusive.no_wrap
; CHECK-NOT:   inclusive.slow
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv) ]

; PIPELINE-LABEL: @runtime_inclusive_decreasing_i32(
; PIPELINE:       %inclusive.no_wrap = icmp sgt i32 %inclusive.limit.fr, -2147483648
; PIPELINE-DAG:   loop.inclusive.slow:
; PIPELINE-DAG:   loop.outer:
; PIPELINE-DAG:   loop.outer.latch:

; PIPELINE-LABEL: @runtime_inclusive_decreasing_unguarded_latch_i32(
; PIPELINE:       %inclusive.first_iteration = icmp sge i32 %inclusive.start.fr, %inclusive.limit.fr
; PIPELINE:       %inclusive.no_wrap = icmp sgt i32 %inclusive.limit.fr, -2147483648
; PIPELINE-DAG:   loop.inclusive.slow:
; PIPELINE-DAG:   loop.outer:

; PIPELINE-LABEL: @runtime_inclusive_decreasing_header_i32(
; PIPELINE:       %inclusive.no_wrap = icmp sgt i32 %inclusive.limit.fr, -2147483648
; PIPELINE-DAG:   body.inclusive.slow:
; PIPELINE-DAG:   body.outer:
; PIPELINE-DAG:   body.outer.latch:
