; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-strip-mining<inclusive-loop-versioning>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' \
; RUN:   -jeandle-enable-inclusive-loop-versioning \
; RUN:   -jeandle-loop-strip-mining-iter=8 \
; RUN:   -verify-each -S < %s | FileCheck %s
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,early-cse,instcombine,simplifycfg,loop-simplify,lcssa,safepoint-strip-mining<inclusive-loop-versioning>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' \
; RUN:   -jeandle-enable-inclusive-loop-versioning \
; RUN:   -jeandle-loop-strip-mining-iter=8 \
; RUN:   -verify-each -S < %s | FileCheck %s --check-prefix=PIPELINE
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-strip-mining<inclusive-loop-versioning>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-enable-inclusive-loop-versioning \
; RUN:   -jeandle-loop-strip-mining-iter=8 \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -verify-each -disable-output < %s
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-strip-mining<inclusive-loop-versioning>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' \
; RUN:   -jeandle-enable-inclusive-loop-versioning=false \
; RUN:   -jeandle-loop-strip-mining-iter=8 -S < %s | FileCheck %s --check-prefix=DISABLED

; Frontend-derived signed i32 inclusive loops with non-unit control IVs. The
; secondary unit-stride recurrence keeps the memory shape independent from the
; loop-control stride. Unsupported legal shapes below must retain their polls.

declare hotspotcc void @jeandle.safepoint_poll()

define i64 @runtime_inclusive_inc_step2(ptr addrspace(1) %array, i32 %start,
                                        i32 %limit) "java-method" {
entry:
  br label %loop

loop:
  %iv = phi i32 [ %start, %entry ], [ %iv.next, %loop ]
  %index = phi i32 [ 0, %entry ], [ %index.next, %loop ]
  %sum = phi i64 [ 0, %entry ], [ %sum.next, %loop ]
  %address = getelementptr i32, ptr addrspace(1) %array, i32 %index
  %value = load atomic i32, ptr addrspace(1) %address unordered, align 4
  %wide = sext i32 %value to i64
  %sum.next = add i64 %sum, %wide
  %index.next = add i32 %index, 1
  %iv.next = add i32 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(ptr addrspace(1) %array, i64 %sum.next, i32 %index.next, i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop

exit:
  %result = phi i64 [ %sum.next, %loop ]
  ret i64 %result
}

; The frontend exposes the unit-stride array index as another exit recurrence.
; Versioning must skip that already-safe candidate and select the runtime-risk
; inclusive control IV rather than leaving the loop without a slow clone.
define i64 @runtime_inclusive_inc_step2_bounds_exit(ptr addrspace(1) %array,
                                                    i32 %length, i32 %start,
                                                    i32 %limit) "java-method" {
entry:
  br label %loop

loop:
  %iv = phi i32 [ %start, %entry ], [ %iv.next, %body ]
  %index = phi i32 [ 0, %entry ], [ %index.next, %body ]
  %sum = phi i64 [ 0, %entry ], [ %sum.next, %body ]
  %in.bounds = icmp ult i32 %index, %length
  br i1 %in.bounds, label %body, label %bounds.fail

body:
  %address = getelementptr i32, ptr addrspace(1) %array, i32 %index
  %value = load atomic i32, ptr addrspace(1) %address unordered, align 4
  %wide = sext i32 %value to i64
  %sum.next = add i64 %sum, %wide
  %index.next = add i32 %index, 1
  %iv.next = add i32 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(ptr addrspace(1) %array, i64 %sum.next, i32 %index.next, i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop

bounds.fail:
  ret i64 -1

exit:
  %result = phi i64 [ %sum.next, %body ]
  ret i64 %result
}

define i64 @runtime_inclusive_inc_step3_header(ptr %array, i32 %start,
                                                i32 %limit) "java-method" {
entry:
  br label %header

header:
  %iv = phi i32 [ %start, %entry ], [ %iv.next, %body ]
  %index = phi i32 [ 0, %entry ], [ %index.next, %body ]
  %sum = phi i64 [ 0, %entry ], [ %sum.next, %body ]
  %continue = icmp sle i32 %iv, %limit
  br i1 %continue, label %body, label %exit

body:
  %address = getelementptr i32, ptr %array, i32 %index
  %value = load i32, ptr %address, align 4
  %wide = sext i32 %value to i64
  %sum.next = add i64 %sum, %wide
  %index.next = add i32 %index, 1
  %iv.next = add i32 %iv, 3
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %sum.next, i32 %index.next, i32 %iv.next) ]
  br label %header

exit:
  %result = phi i64 [ %sum, %header ]
  ret i64 %result
}

define i64 @runtime_inclusive_dec_step2(ptr addrspace(1) %array, i32 %start,
                                        i32 %limit) "java-method" {
entry:
  br label %loop

loop:
  %iv = phi i32 [ %start, %entry ], [ %iv.next, %loop ]
  %index = phi i32 [ 0, %entry ], [ %index.next, %loop ]
  %sum = phi i64 [ 0, %entry ], [ %sum.next, %loop ]
  %address = getelementptr i32, ptr addrspace(1) %array, i32 %index
  %value = load atomic i32, ptr addrspace(1) %address unordered, align 4
  %wide = sext i32 %value to i64
  %sum.next = add i64 %sum, %wide
  %index.next = add i32 %index, 1
  %iv.next = add i32 %iv, -2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(ptr addrspace(1) %array, i64 %sum.next, i32 %index.next, i32 %iv.next) ]
  %done = icmp slt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop

exit:
  %result = phi i64 [ %sum.next, %loop ]
  ret i64 %result
}

define i64 @runtime_inclusive_dec_step3_header(ptr %array, i32 %start,
                                                i32 %limit) "java-method" {
entry:
  br label %header

header:
  %iv = phi i32 [ %start, %entry ], [ %iv.next, %body ]
  %index = phi i32 [ 0, %entry ], [ %index.next, %body ]
  %sum = phi i64 [ 0, %entry ], [ %sum.next, %body ]
  %continue = icmp sge i32 %iv, %limit
  br i1 %continue, label %body, label %exit

body:
  %address = getelementptr i32, ptr %array, i32 %index
  %value = load i32, ptr %address, align 4
  %wide = sext i32 %value to i64
  %sum.next = add i64 %sum, %wide
  %index.next = add i32 %index, 1
  %iv.next = add i32 %iv, -3
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %sum.next, i32 %index.next, i32 %iv.next) ]
  br label %header

exit:
  %result = phi i64 [ %sum, %header ]
  ret i64 %result
}

; The slow-clone marker is a conservative barrier to later strip mining, not a
; no-wrap certificate. The unmarked control proves this shape is otherwise
; statically strip-mineable.
define void @static_no_wrap_step2(i32 %start, i32 %limit) "java-method" {
entry:
  %safe.limit = icmp slt i32 %limit, 2147483646
  br i1 %safe.limit, label %nonempty.check, label %exit

nonempty.check:
  %nonempty = icmp sle i32 %start, %limit
  br i1 %nonempty, label %preheader, label %exit

preheader:
  br label %loop

loop:
  %iv = phi i32 [ %start, %preheader ], [ %iv.next, %loop ]
  %iv.next = add i32 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, %limit
  br i1 %done, label %loopexit, label %loop

loopexit:
  br label %exit

exit:
  ret void
}

define void @marked_static_no_wrap_step2(i32 %start, i32 %limit) "java-method" {
entry:
  %safe.limit = icmp slt i32 %limit, 2147483646
  br i1 %safe.limit, label %nonempty.check, label %exit

nonempty.check:
  %nonempty = icmp sle i32 %start, %limit
  br i1 %nonempty, label %preheader, label %exit

preheader:
  br label %loop

loop:
  %iv = phi i32 [ %start, %preheader ], [ %iv.next, %loop ]
  %iv.next = add i32 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, %limit
  br i1 %done, label %loopexit, label %loop, !jeandle.inclusive.slow !0

loopexit:
  br label %exit

exit:
  ret void
}

define void @runtime_inclusive_dynamic_step(i32 %limit, i32 %step) "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop ]
  %iv.next = add i32 %iv, %step
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

define void @runtime_inclusive_zero_step(i32 %limit) "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop ]
  %iv.next = add i32 %iv, 0
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

define void @runtime_inclusive_direction_mismatch(i32 %limit) "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop ]
  %iv.next = add i32 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp slt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

define void @runtime_inclusive_int_min_step(i32 %start, i32 %limit) "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i32 [ %start, %entry ], [ %iv.next, %loop ]
  %iv.next = add i32 %iv, -2147483648
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp slt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

define void @runtime_inclusive_chunk_overflow(i32 %limit) "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop ]
  %iv.next = add i32 %iv, 1073741824
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

define void @runtime_inclusive_unsigned_step2(i32 %limit) "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop ]
  %iv.next = add i32 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp ugt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

define void @runtime_inclusive_i64_step2(i64 %limit) "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %loop ]
  %iv.next = add i64 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  %done = icmp sgt i64 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

define void @runtime_ne_step2(i32 %limit) "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop ]
  %iv.next = add i32 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp eq i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

!java-method-compilation = !{}
!0 = !{}

; CHECK-LABEL: @runtime_inclusive_inc_step2(
; CHECK:       %inclusive.no_wrap = icmp slt i32 %inclusive.limit.fr, 2147483646
; CHECK-DAG:   %outer.batch.dist = sub nsw i64
; CHECK-DAG:   call i64 @llvm.smin.i64
; CHECK-DAG:   %outer.inner.limit = add nsw i32 %outer.iv, %outer.batch.chunk
; CHECK-DAG:   loop.outer.latch:
; CHECK-DAG:   call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}} [ "deopt"({{.*}}%outer.iv.next) ]
; CHECK-DAG:   loop.inclusive.slow:
; CHECK-DAG:   call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(ptr addrspace(1) %array, i64 %sum.next.inclusive.slow, i32 %index.next.inclusive.slow, i32 %iv.next.inclusive.slow) ]

; CHECK-LABEL: @runtime_inclusive_inc_step2_bounds_exit(
; CHECK:       %inclusive.no_wrap = icmp slt i32 %inclusive.limit.fr, 2147483646
; CHECK-DAG:   loop.inclusive.slow:
; CHECK-NOT:   loop.inclusive.slow.outer
; CHECK-DAG:   loop.outer.latch:
; CHECK-DAG:   bounds.fail:

; CHECK-LABEL: @runtime_inclusive_inc_step3_header(
; CHECK:       %inclusive.no_wrap = icmp slt i32 %inclusive.limit.fr, 2147483645
; CHECK-DAG:   %outer.batch.dist = sub nsw i64
; CHECK-DAG:   call i64 @llvm.smin.i64
; CHECK-DAG:   %outer.inner.limit = add nsw i32 %outer.iv, %outer.batch.chunk
; CHECK-DAG:   body.outer.latch:
; CHECK-DAG:   body.inclusive.slow:

; CHECK-LABEL: @runtime_inclusive_dec_step2(
; CHECK:       %inclusive.no_wrap = icmp sgt i32 %inclusive.limit.fr, -2147483647
; CHECK-DAG:   %outer.batch.dist = sub nsw i64
; CHECK-DAG:   call i64 @llvm.smin.i64
; CHECK-DAG:   %outer.inner.limit = sub nsw i32 %outer.iv, %outer.batch.chunk
; CHECK-DAG:   loop.outer.latch:
; CHECK-DAG:   loop.inclusive.slow:

; CHECK-LABEL: @runtime_inclusive_dec_step3_header(
; CHECK:       %inclusive.no_wrap = icmp sgt i32 %inclusive.limit.fr, -2147483646
; CHECK-DAG:   %outer.batch.dist = sub nsw i64
; CHECK-DAG:   call i64 @llvm.smin.i64
; CHECK-DAG:   %outer.inner.limit = sub nsw i32 %outer.iv, %outer.batch.chunk
; CHECK-DAG:   body.outer.latch:
; CHECK-DAG:   body.inclusive.slow:

; CHECK-LABEL: @static_no_wrap_step2(
; CHECK:       loop.outer.latch:
; CHECK-LABEL: @marked_static_no_wrap_step2(
; CHECK-NOT:   loop.outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       br i1 %done, label %loopexit, label %loop, !jeandle.inclusive.slow

; CHECK-LABEL: @runtime_inclusive_dynamic_step(
; CHECK-NOT:   inclusive.no_wrap
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
; CHECK-LABEL: @runtime_inclusive_zero_step(
; CHECK-NOT:   inclusive.no_wrap
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
; CHECK-LABEL: @runtime_inclusive_direction_mismatch(
; CHECK-NOT:   inclusive.no_wrap
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
; CHECK-LABEL: @runtime_inclusive_int_min_step(
; CHECK-NOT:   inclusive.no_wrap
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
; CHECK-LABEL: @runtime_inclusive_chunk_overflow(
; CHECK-NOT:   inclusive.no_wrap
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
; CHECK-LABEL: @runtime_inclusive_unsigned_step2(
; CHECK-NOT:   inclusive.no_wrap
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
; CHECK-LABEL: @runtime_inclusive_i64_step2(
; CHECK-NOT:   inclusive.no_wrap
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
; CHECK-LABEL: @runtime_ne_step2(
; CHECK-NOT:   inclusive.no_wrap
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()

; PIPELINE-LABEL: @runtime_inclusive_inc_step2(
; PIPELINE:       %inclusive.no_wrap = icmp slt i32 %inclusive.limit.fr, 2147483646
; PIPELINE-DAG:   loop.outer.latch:
; PIPELINE-DAG:   loop.inclusive.slow:
; PIPELINE-LABEL: @runtime_inclusive_inc_step2_bounds_exit(
; PIPELINE:       %inclusive.no_wrap = icmp slt i32 %inclusive.limit.fr, 2147483646
; PIPELINE-DAG:   loop.outer.latch:
; PIPELINE-DAG:   loop.inclusive.slow:
; PIPELINE-NOT:   loop.inclusive.slow.outer
; PIPELINE-LABEL: @runtime_inclusive_dec_step3_header(
; PIPELINE:       %inclusive.no_wrap = icmp sgt i32 %inclusive.limit.fr, -2147483646
; PIPELINE-DAG:   body.outer.latch:
; PIPELINE-DAG:   body.inclusive.slow:
; PIPELINE-LABEL: @static_no_wrap_step2(
; PIPELINE:       loop.outer.latch:
; PIPELINE-LABEL: @marked_static_no_wrap_step2(
; PIPELINE-NOT:   loop.outer
; PIPELINE:       call hotspotcc void @jeandle.safepoint_poll()
; PIPELINE-LABEL: @runtime_inclusive_dynamic_step(
; PIPELINE-NOT:   inclusive.no_wrap
; PIPELINE:       call hotspotcc void @jeandle.safepoint_poll()

; DISABLED-LABEL: @runtime_inclusive_inc_step2(
; DISABLED-NOT:   inclusive.no_wrap
; DISABLED-NOT:   inclusive.slow
; DISABLED:       call hotspotcc void @jeandle.safepoint_poll()
; DISABLED-LABEL: @runtime_inclusive_inc_step2_bounds_exit(
; DISABLED-NOT:   inclusive.no_wrap
; DISABLED-NOT:   inclusive.slow
; DISABLED:       call hotspotcc void @jeandle.safepoint_poll()
; DISABLED-LABEL: @runtime_inclusive_dec_step3_header(
; DISABLED-NOT:   inclusive.no_wrap
; DISABLED-NOT:   inclusive.slow
; DISABLED:       call hotspotcc void @jeandle.safepoint_poll()
