; RUN: opt -passes='loop-simplify,lcssa,safepoint-strip-mining<inclusive-loop-versioning>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-enable-inclusive-loop-versioning \
; RUN:   -jeandle-loop-strip-mining-iter=8 -jeandle-verify-safepoint-coverage=fatal \
; RUN:   -verify-each -S < %s | FileCheck %s
; RUN: opt -passes='early-cse,instcombine,simplifycfg,loop-simplify,lcssa,safepoint-strip-mining<inclusive-loop-versioning>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-enable-inclusive-loop-versioning \
; RUN:   -jeandle-loop-strip-mining-iter=8 -jeandle-verify-safepoint-coverage=fatal \
; RUN:   -verify-each -S < %s | FileCheck %s --check-prefix=PIPELINE

; Minimized from the frontend input for a nested Java loop. The positive loop
; has an independent poll on the outer backedge, so versioning and strip mining
; the runtime-risk inclusive inner loop preserves coverage at both levels. The
; negative loop has no outer poll and executes its inner loop on every outer
; iteration; its inner poll is therefore required by the unbounded ancestor and
; must not be moved.

declare hotspotcc void @jeandle.safepoint_poll()

define i64 @nested_runtime_inclusive_with_outer_poll(i32 %outer.trips,
                                                      i32 %start, i32 %limit) "java-method" {
entry:
  br label %outer.header

outer.header:
  %outer.iv = phi i32 [ 0, %entry ], [ %outer.next, %outer.latch ]
  %outer.sum = phi i64 [ 0, %entry ], [ %sum.after, %outer.latch ]
  %outer.continue = icmp slt i32 %outer.iv, %outer.trips
  br i1 %outer.continue, label %inner.guard, label %exit

inner.guard:
  %inner.nonempty = icmp sle i32 %start, %limit
  br i1 %inner.nonempty, label %inner.preheader, label %outer.latch

inner.preheader:
  br label %inner.header

inner.header:
  %iv = phi i32 [ %start, %inner.preheader ], [ %iv.next, %inner.header ]
  %sum = phi i64 [ %outer.sum, %inner.preheader ], [ %sum.next, %inner.header ]
  %iv.wide = sext i32 %iv to i64
  %sum.next = add i64 %sum, %iv.wide
  %iv.next = add i32 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %outer.iv, i32 %iv.next, i64 %sum.next) ]
  %inner.done = icmp sgt i32 %iv.next, %limit
  br i1 %inner.done, label %inner.exit, label %inner.header

inner.exit:
  %inner.sum.lcssa = phi i64 [ %sum.next, %inner.header ]
  br label %outer.latch

outer.latch:
  %sum.after = phi i64 [ %outer.sum, %inner.guard ], [ %inner.sum.lcssa, %inner.exit ]
  %outer.next = add i32 %outer.iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %outer.next, i64 %sum.after) ]
  br label %outer.header

exit:
  %result = phi i64 [ %outer.sum, %outer.header ]
  ret i64 %result
}

define void @nested_inner_poll_required_by_ancestor(i32 %outer.trips,
                                                     i32 %start, i32 %limit) "java-method" {
entry:
  br label %outer.header

outer.header:
  %outer.iv = phi i32 [ 0, %entry ], [ %outer.next, %outer.latch ]
  %outer.continue = icmp slt i32 %outer.iv, %outer.trips
  br i1 %outer.continue, label %inner.preheader, label %exit

inner.preheader:
  br label %inner.header

inner.header:
  %iv = phi i32 [ %start, %inner.preheader ], [ %iv.next, %inner.header ]
  %iv.next = add i32 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %outer.iv, i32 %iv.next) ]
  %inner.done = icmp sgt i32 %iv.next, %limit
  br i1 %inner.done, label %outer.latch, label %inner.header

outer.latch:
  %outer.next = add i32 %outer.iv, 1
  br label %outer.header

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @nested_runtime_inclusive_with_outer_poll(
; CHECK:       %inclusive.no_wrap = icmp slt i32 %inclusive.limit.fr, 2147483646
; CHECK-DAG:   inner.header.inclusive.slow:
; CHECK-NOT:   inner.header.inclusive.slow.outer
; CHECK-DAG:   inner.header.outer.latch:
; CHECK-DAG:   call hotspotcc void @jeandle.safepoint_poll()
; CHECK-DAG:   outer.latch:
; CHECK-DAG:   call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %outer.next, i64 %sum.after) ]

; CHECK-LABEL: @nested_inner_poll_required_by_ancestor(
; CHECK-NOT:   inclusive.no_wrap
; CHECK-NOT:   inclusive.slow
; CHECK-NOT:   inner.header.outer
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %outer.iv, i32 %iv.next) ]

; PIPELINE-LABEL: @nested_runtime_inclusive_with_outer_poll(
; PIPELINE:       %inclusive.no_wrap = icmp slt i32 %inclusive.limit.fr, 2147483646
; PIPELINE-DAG:   inner.header.inclusive.slow:
; PIPELINE-NOT:   inner.header.inclusive.slow.outer
; PIPELINE-DAG:   inner.header.outer.latch:
; PIPELINE-DAG:   outer.latch:
; PIPELINE-LABEL: @nested_inner_poll_required_by_ancestor(
; PIPELINE-NOT:   inclusive.no_wrap
; PIPELINE:       call hotspotcc void @jeandle.safepoint_poll()
