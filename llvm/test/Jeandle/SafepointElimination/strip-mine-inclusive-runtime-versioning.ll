; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-strip-mining<inclusive-loop-versioning>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' \
; RUN:   -jeandle-enable-inclusive-loop-versioning -verify-each -S < %s | FileCheck %s
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,early-cse,instcombine,simplifycfg,loop-simplify,lcssa,safepoint-strip-mining<inclusive-loop-versioning>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' \
; RUN:   -jeandle-enable-inclusive-loop-versioning -verify-each -S < %s | FileCheck %s --check-prefix=PIPELINE
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,loop-simplify,lcssa,safepoint-strip-mining<inclusive-loop-versioning>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' \
; RUN:   -jeandle-enable-inclusive-loop-versioning -verify-each -S < %s | FileCheck %s --check-prefix=CANONICAL
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-strip-mining<inclusive-loop-versioning>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-enable-inclusive-loop-versioning -jeandle-verify-safepoint-coverage=fatal \
; RUN:   -verify-each -disable-output < %s
; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,loop-simplify,lcssa,safepoint-strip-mining<inclusive-loop-versioning>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-enable-inclusive-loop-versioning -jeandle-verify-safepoint-coverage=fatal \
; RUN:   -verify-each -disable-output < %s

; Minimized from the SafepointElimination input for the Java shape:
;
;   for (int i = start; i <= limit; i++) sum += a[i - start];
;
; The runtime no-wrap guard versions the loop. The safe path is strip-mined,
; while limit == INT_MAX retains the original polling loop and its next-
; iteration deopt state.

declare hotspotcc void @jeandle.safepoint_poll()
declare hotspotcc i64 @llvm.experimental.deoptimize.i64(...)
declare hotspotcc void @java_invoke()
declare void @noduplicate_call() noduplicate
declare void @convergent_call() convergent
declare void @token_consume()
declare void @may_throw()
declare i32 @__gxx_personality_v0(...)
declare token @llvm.coro.save(ptr)

define i64 @runtime_inclusive_i32(ptr %a, i32 %start, i32 %limit) "java-method" {
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

; Minimized from the real AArch64 frontend IR for inclusiveReduction(int[],
; int, int). The addrspace(1) oop, null/bounds deopt exits, LCSSA payloads, and
; next-iteration poll state are retained.
define i64 @runtime_inclusive_i32_deopt_exits(ptr addrspace(1) %array,
                                               i32 %start, i32 %limit,
                                               i32 %length) "java-method" {
entry:
  %nonempty = icmp sle i32 %start, %limit
  br i1 %nonempty, label %preheader, label %exit

preheader:
  br label %loop

loop:
  %iv = phi i32 [ %start, %preheader ], [ %iv.next, %body ]
  %sum = phi i64 [ 0, %preheader ], [ %sum.next, %body ]
  %is.null = icmp eq ptr addrspace(1) %array, null
  br i1 %is.null, label %null.fail, label %bounds.check

bounds.check:
  %index = sub i32 %iv, %start
  %in.bounds = icmp ult i32 %index, %length
  br i1 %in.bounds, label %body, label %bounds.fail

body:
  %address = getelementptr i32, ptr addrspace(1) %array, i32 %index
  %value = load atomic i32, ptr addrspace(1) %address unordered, align 4
  %wide = sext i32 %value to i64
  %sum.next = add i64 %sum, %wide
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(ptr addrspace(1) %array, i64 %sum.next, i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, %limit
  br i1 %done, label %primary.loopexit, label %loop

null.fail:
  %null.iv = phi i32 [ %iv, %loop ]
  %null.sum = phi i64 [ %sum, %loop ]
  %null.result = call hotspotcc i64 (...) @llvm.experimental.deoptimize.i64(i32 -10) [ "deopt"(ptr addrspace(1) %array, i64 %null.sum, i32 %null.iv) ]
  ret i64 %null.result

bounds.fail:
  %bounds.iv = phi i32 [ %iv, %bounds.check ]
  %bounds.sum = phi i64 [ %sum, %bounds.check ]
  %bounds.index = phi i32 [ %index, %bounds.check ]
  %bounds.result = call hotspotcc i64 (...) @llvm.experimental.deoptimize.i64(i32 -26) [ "deopt"(ptr addrspace(1) %array, i64 %bounds.sum, i32 %bounds.iv, i32 %bounds.index) ]
  ret i64 %bounds.result

primary.loopexit:
  %result = phi i64 [ %sum.next, %body ]
  br label %exit

exit:
  %final = phi i64 [ 0, %entry ], [ %result, %primary.loopexit ]
  ret i64 %final
}

; Bounds that SCEV cannot model as one stable recurrence limit remain outside
; the direct-pass envelope. The pipeline fixture also covers InstCombine
; refining a poison-producing select to its only defined value.
define void @runtime_inclusive_undef_limit(i32 %start) "java-method" {
entry:
  %nonempty = icmp sle i32 %start, undef
  br i1 %nonempty, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i32 [ %start, %preheader ], [ %iv.next, %loop ]
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, undef
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

; SCEV can range-bound these values, but transitive uses of the undef-dependent
; instruction need not agree. Versioning must freeze the runtime operand before
; using it in both the batch clamp and the inner exit test.
define void @runtime_inclusive_masked_undef_limit() "java-method" {
entry:
  %limit = and i32 undef, 2147483646
  %nonempty = icmp sle i32 0, %limit
  br i1 %nonempty, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i32 [ 0, %preheader ], [ %iv.next, %loop ]
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

define void @runtime_inclusive_masked_undef_start() "java-method" {
entry:
  %start = and i32 undef, 2147483646
  %nonempty = icmp sle i32 %start, 2147483646
  br i1 %nonempty, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i32 [ %start, %preheader ], [ %iv.next, %loop ]
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, 2147483646
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

; This latch-tested shape has no entry guard. The frozen start can make the
; first iteration either legal or illegal, so the reachable slow clone must
; preserve the original one-iteration semantics and its poll.
define i32 @runtime_inclusive_masked_undef_start_observable() "java-method" {
entry:
  %start = and i32 undef, 4095
  br label %loop
loop:
  %iv = phi i32 [ %start, %entry ], [ %iv.next, %loop ]
  %count = phi i32 [ 0, %entry ], [ %count.next, %loop ]
  %count.next = add i32 %count, 1
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %count.next, i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, 2047
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %count.next, %loop ]
  ret i32 %result
}

define void @runtime_inclusive_maybe_poison_limit(i32 %start, i32 %limit,
                                                   i1 %choose.limit) "java-method" {
entry:
  %maybe.poison = select i1 %choose.limit, i32 %limit, i32 poison
  %nonempty = icmp sle i32 %start, %maybe.poison
  br i1 %nonempty, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i32 [ %start, %preheader ], [ %iv.next, %loop ]
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, %maybe.poison
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

; Unsigned, wider, and deopt-state shapes are legal IR but outside the runtime
; versioning envelope. They must retain the original poll.

define void @runtime_inclusive_unsigned_i32(i32 %limit) "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop ]
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp ugt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

define void @runtime_inclusive_i64(i64 %limit) "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %loop ]
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  %done = icmp sgt i64 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

define void @runtime_inclusive_step2_i32(i32 %limit) "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop ]
  %iv.next = add i32 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

define void @runtime_inclusive_current_phi_deopt(i32 %limit) "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop ]
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv) ]
  %done = icmp sgt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

; Cloning restrictions are independent of the counted-loop proof. Each case
; otherwise matches the supported runtime-versioning shape and must bail.
define void @runtime_inclusive_noduplicate(i32 %limit) "java-method" {
entry:
  %nonempty = icmp sle i32 0, %limit
  br i1 %nonempty, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i32 [ 0, %preheader ], [ %iv.next, %loop ]
  call void @noduplicate_call()
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

define void @runtime_inclusive_convergent(i32 %limit) "java-method" {
entry:
  %nonempty = icmp sle i32 0, %limit
  br i1 %nonempty, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i32 [ 0, %preheader ], [ %iv.next, %loop ]
  call void @convergent_call()
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

; The direct pass must not clone this cross-block token. SimplifyCFG can merge
; the two loop blocks first, after which the token no longer crosses a block.
define void @runtime_inclusive_cross_block_token(i32 %limit) "java-method" {
entry:
  %nonempty = icmp sle i32 0, %limit
  br i1 %nonempty, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i32 [ 0, %preheader ], [ %iv.next, %latch ]
  %loop.token = call token @llvm.coro.save(ptr null)
  br label %latch
latch:
  call void @token_consume() [ "token"(token %loop.token) ]
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

define void @runtime_inclusive_eh(i32 %limit) "java-method"
    personality ptr @__gxx_personality_v0 {
entry:
  %nonempty = icmp sle i32 0, %limit
  br i1 %nonempty, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i32 [ 0, %preheader ], [ %iv.next, %latch ]
  invoke void @may_throw()
          to label %latch unwind label %exception
latch:
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exception:
  %landing = landingpad { ptr, i32 }
          cleanup
  ret void
exit:
  ret void
}

define void @runtime_inclusive_statepoint_id(i32 %limit) "java-method" {
entry:
  %nonempty = icmp sle i32 0, %limit
  br i1 %nonempty, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i32 [ 0, %preheader ], [ %iv.next, %loop ]
  call hotspotcc void @java_invoke() #0 [ "deopt"(i32 %iv) ]
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

define void @runtime_inclusive_indirectbr(i32 %limit, ptr %destination) "java-method" {
entry:
  %nonempty = icmp sle i32 0, %limit
  br i1 %nonempty, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i32 [ 0, %preheader ], [ %iv.next, %latch ]
  indirectbr ptr %destination, [label %latch, label %side.exit]
latch:
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
side.exit:
  ret void
exit:
  ret void
}

; Every loop predecessor contributes a distinct LCSSA value. Versioning must
; repair all cloned incoming edges, not only the primary counted exit.
define i32 @runtime_inclusive_shared_exit_phis(i32 %limit, i1 %side0,
                                                i1 %side1) "java-method" {
entry:
  br label %loop
loop:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %latch ]
  %sum = phi i32 [ 0, %entry ], [ %sum.next, %latch ]
  br i1 %side0, label %exit, label %body
body:
  br i1 %side1, label %exit, label %latch
latch:
  %sum.next = add i32 %sum, %iv
  %iv.next = add i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %sum.next, i32 %iv.next) ]
  %done = icmp sgt i32 %iv.next, %limit
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %sum, %loop ], [ %sum, %body ],
                    [ %sum.next, %latch ]
  ret i32 %result
}

; Applying the first precomputed plan mutates LoopInfo and the dominator tree.
; The second independent plan must remain valid and be applied as well.
define void @runtime_inclusive_two_plans(i32 %limit1, i32 %limit2) "java-method" {
entry:
  br label %loop1
loop1:
  %iv1 = phi i32 [ 0, %entry ], [ %iv1.next, %loop1 ]
  %iv1.next = add i32 %iv1, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv1.next) ]
  %done1 = icmp sgt i32 %iv1.next, %limit1
  br i1 %done1, label %between, label %loop1
between:
  br label %loop2
loop2:
  %iv2 = phi i32 [ 0, %between ], [ %iv2.next, %loop2 ]
  %iv2.next = add i32 %iv2, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv2.next) ]
  %done2 = icmp sgt i32 %iv2.next, %limit2
  br i1 %done2, label %exit, label %loop2
exit:
  ret void
}

attributes #0 = { "statepoint-id"="7" }

!java-method-compilation = !{}

; CHECK-LABEL: @runtime_inclusive_i32(
; CHECK:       %inclusive.limit.fr = freeze i32 %limit
; CHECK:       %inclusive.start.fr = freeze i32 %start
; CHECK:       %inclusive.first_iteration = icmp sle i32 %inclusive.start.fr, %inclusive.limit.fr
; CHECK:       %inclusive.no_wrap = icmp slt i32 %inclusive.limit.fr, 2147483647
; CHECK:       br i1 %inclusive.no_wrap
; CHECK-DAG:   loop.outer:
; CHECK-DAG:   loop.outer.latch:
; CHECK-DAG:   call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}} [ "deopt"({{.*}}%outer.iv.next) ]
; CHECK-DAG:   loop.inclusive.slow:
; CHECK-DAG:   call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %sum.next.inclusive.slow, i32 %iv.next.inclusive.slow) ]

; CHECK-LABEL: @runtime_inclusive_i32_deopt_exits(
; CHECK:       %inclusive.limit.fr = freeze i32 %limit
; CHECK:       %inclusive.no_wrap = icmp slt i32 %inclusive.limit.fr, 2147483647
; CHECK-DAG:   loop.outer:
; CHECK-DAG:   null.fail:
; CHECK-DAG:   @llvm.experimental.deoptimize.i64
; CHECK-DAG:   bounds.fail:
; CHECK-DAG:   ptr addrspace(1) %array
; CHECK-DAG:   loop.inclusive.slow:
; CHECK-DAG:   call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(ptr addrspace(1) %array, i64 %sum.next.inclusive.slow, i32 %iv.next.inclusive.slow) ]

; CHECK-LABEL: @runtime_inclusive_undef_limit(
; CHECK:       %inclusive.limit.fr = freeze i32 undef
; CHECK-DAG:   loop.inclusive.slow:
; CHECK-DAG:   loop.outer:
; CHECK-DAG:   call hotspotcc void @jeandle.safepoint_poll()

; CHECK-LABEL: @runtime_inclusive_masked_undef_limit(
; CHECK:   inclusive.no_wrap
; CHECK-DAG:   loop.inclusive.slow:
; CHECK-DAG:   loop.outer:
; CHECK-DAG:   call hotspotcc void @jeandle.safepoint_poll()

; CHECK-LABEL: @runtime_inclusive_masked_undef_start(
; CHECK:   inclusive.no_wrap
; CHECK-DAG:   loop.inclusive.slow:
; CHECK-DAG:   loop.outer:
; CHECK-DAG:   call hotspotcc void @jeandle.safepoint_poll()

; CHECK-LABEL: @runtime_inclusive_masked_undef_start_observable(
; CHECK:   inclusive.no_wrap
; CHECK-DAG:   loop.inclusive.slow:
; CHECK-DAG:   loop.outer:
; CHECK-DAG:   call hotspotcc void @jeandle.safepoint_poll()

; CHECK-LABEL: @runtime_inclusive_maybe_poison_limit(
; CHECK:       %inclusive.limit.fr = freeze i32 %maybe.poison
; CHECK-DAG:   loop.inclusive.slow:
; CHECK-DAG:   loop.outer:
; CHECK-DAG:   call hotspotcc void @jeandle.safepoint_poll()

; CHECK-LABEL: @runtime_inclusive_unsigned_i32(
; CHECK-NOT:   inclusive.no_wrap
; CHECK-NOT:   inclusive.slow
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()

; CHECK-LABEL: @runtime_inclusive_i64(
; CHECK-NOT:   inclusive.no_wrap
; CHECK-NOT:   inclusive.slow
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()

; CHECK-LABEL: @runtime_inclusive_step2_i32(
; CHECK:       %inclusive.no_wrap = icmp slt i32 %inclusive.limit.fr, 2147483646
; CHECK-DAG:   loop.inclusive.slow:
; CHECK-DAG:   loop.outer:
; CHECK-DAG:   loop.outer.latch:

; CHECK-LABEL: @runtime_inclusive_current_phi_deopt(
; CHECK-NOT:   inclusive.no_wrap
; CHECK-NOT:   inclusive.slow
; CHECK:       call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv) ]

; CHECK-LABEL: @runtime_inclusive_noduplicate(
; CHECK-NOT:   inclusive.no_wrap
; CHECK-NOT:   inclusive.slow
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()

; CHECK-LABEL: @runtime_inclusive_convergent(
; CHECK-NOT:   inclusive.no_wrap
; CHECK-NOT:   inclusive.slow
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()

; CHECK-LABEL: @runtime_inclusive_cross_block_token(
; CHECK-NOT:   inclusive.no_wrap
; CHECK-NOT:   inclusive.slow
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()

; CHECK-LABEL: @runtime_inclusive_eh(
; CHECK-NOT:   inclusive.no_wrap
; CHECK-NOT:   inclusive.slow
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()

; CHECK-LABEL: @runtime_inclusive_statepoint_id(
; CHECK-NOT:   inclusive.no_wrap
; CHECK-NOT:   inclusive.slow
; The loop body's java_invoke is a guaranteed-safepoint call covering the loop,
; so the complete-deletion pass removes the now-redundant back-edge poll.
; CHECK-NOT:   call hotspotcc void @jeandle.safepoint_poll

; CHECK-LABEL: @runtime_inclusive_indirectbr(
; CHECK-NOT:   inclusive.no_wrap
; CHECK-NOT:   inclusive.slow
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()

; CHECK-LABEL: @runtime_inclusive_shared_exit_phis(
; CHECK:       loop.inclusive.slow:
; CHECK:       %result.ph = phi i32 [ %sum.next.inclusive.slow, %latch.inclusive.slow ], [ %sum.inclusive.slow, %body.inclusive.slow ], [ %sum.inclusive.slow, %loop.inclusive.slow ]
; CHECK:       %result.ph2 = phi i32 [ %sum.outer, %loop.outer ], [ %sum, %body ], [ %sum, %loop ]
; CHECK:       %result = phi i32 [ %result.ph, %exit.loopexit ], [ %result.ph2, %exit.loopexit1 ]
; CHECK:       loop.outer:
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()

; CHECK-LABEL: @runtime_inclusive_two_plans(
; CHECK-DAG:   loop1.outer:
; CHECK-DAG:   loop1.outer.latch:
; CHECK-DAG:   loop1.inclusive.slow:
; CHECK-DAG:   loop2.outer:
; CHECK-DAG:   loop2.outer.latch:
; CHECK-DAG:   loop2.inclusive.slow:

; PIPELINE-LABEL: @runtime_inclusive_i32(
; PIPELINE:       %inclusive.limit.fr = freeze i32 %limit
; PIPELINE:       %inclusive.no_wrap = icmp slt i32 %inclusive.limit.fr, 2147483647
; PIPELINE-DAG:   loop.outer:
; PIPELINE-DAG:   loop.outer.latch:
; PIPELINE-DAG:   call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}} [ "deopt"({{.*}}%outer.iv.next) ]
; PIPELINE-DAG:   loop.inclusive.slow:
; PIPELINE-DAG:   call hotspotcc void @jeandle.safepoint_poll()

; PIPELINE-LABEL: @runtime_inclusive_i32_deopt_exits(
; PIPELINE:       %inclusive.limit.fr = freeze i32 %limit
; PIPELINE:       %inclusive.no_wrap = icmp slt i32 %inclusive.limit.fr, 2147483647
; PIPELINE-DAG:   loop.outer:
; PIPELINE-DAG:   @llvm.experimental.deoptimize.i64
; PIPELINE-DAG:   ptr addrspace(1) %array
; PIPELINE-DAG:   loop.inclusive.slow:
; PIPELINE-DAG:   call hotspotcc void @jeandle.safepoint_poll()

; PIPELINE-LABEL: @runtime_inclusive_undef_limit(
; PIPELINE-NOT:   inclusive.no_wrap
; PIPELINE:       call hotspotcc void @jeandle.safepoint_poll()

; PIPELINE-LABEL: @runtime_inclusive_maybe_poison_limit(
; PIPELINE:       %inclusive.limit.fr = freeze i32 %limit
; PIPELINE:       %inclusive.no_wrap = icmp slt i32 %inclusive.limit.fr, 2147483647
; PIPELINE-DAG:   loop.outer:
; PIPELINE-DAG:   loop.inclusive.slow:

; PIPELINE-LABEL: @runtime_inclusive_unsigned_i32(
; PIPELINE-NOT:   inclusive.no_wrap
; PIPELINE:       call hotspotcc void @jeandle.safepoint_poll()

; PIPELINE-LABEL: @runtime_inclusive_i64(
; PIPELINE-NOT:   inclusive.no_wrap
; PIPELINE:       call hotspotcc void @jeandle.safepoint_poll()

; PIPELINE-LABEL: @runtime_inclusive_step2_i32(
; PIPELINE:       %inclusive.no_wrap = icmp slt i32 %inclusive.limit.fr, 2147483646
; PIPELINE-DAG:   loop.inclusive.slow:
; PIPELINE-DAG:   loop.outer:

; PIPELINE-LABEL: @runtime_inclusive_current_phi_deopt(
; PIPELINE-NOT:   inclusive.no_wrap
; PIPELINE:       call hotspotcc void @jeandle.safepoint_poll()

; PIPELINE-LABEL: @runtime_inclusive_noduplicate(
; PIPELINE-NOT:   inclusive.no_wrap
; PIPELINE:       call hotspotcc void @jeandle.safepoint_poll()

; PIPELINE-LABEL: @runtime_inclusive_convergent(
; PIPELINE-NOT:   inclusive.no_wrap
; PIPELINE:       call hotspotcc void @jeandle.safepoint_poll()

; PIPELINE-LABEL: @runtime_inclusive_cross_block_token(
; PIPELINE:       %inclusive.no_wrap = icmp slt i32 %inclusive.limit.fr, 2147483647
; PIPELINE-DAG:   loop.outer:
; PIPELINE-DAG:   loop.inclusive.slow:

; PIPELINE-LABEL: @runtime_inclusive_eh(
; PIPELINE-NOT:   inclusive.no_wrap
; PIPELINE:       call hotspotcc void @jeandle.safepoint_poll()

; PIPELINE-LABEL: @runtime_inclusive_statepoint_id(
; PIPELINE-NOT:   inclusive.no_wrap
; PIPELINE-NOT:   call hotspotcc void @jeandle.safepoint_poll

; PIPELINE-LABEL: @runtime_inclusive_indirectbr(
; PIPELINE-NOT:   inclusive.no_wrap
; PIPELINE:       ret void

; CANONICAL-LABEL: @runtime_inclusive_masked_undef_limit(
; CANONICAL:   inclusive.no_wrap
; CANONICAL:   loop.outer
; CANONICAL:   call hotspotcc void @jeandle.safepoint_poll()

; CANONICAL-LABEL: @runtime_inclusive_masked_undef_start(
; CANONICAL:   inclusive.no_wrap
; CANONICAL:   loop.outer
; CANONICAL:   call hotspotcc void @jeandle.safepoint_poll()

; CANONICAL-LABEL: @runtime_inclusive_masked_undef_start_observable(
; CANONICAL:   inclusive.no_wrap
; CANONICAL:   loop.outer
; CANONICAL:   call hotspotcc void @jeandle.safepoint_poll()

; CANONICAL-LABEL: @runtime_inclusive_maybe_poison_limit(
; CANONICAL:       %inclusive.limit.fr = freeze i32 %maybe.poison
; CANONICAL-DAG:   loop.inclusive.slow:
; CANONICAL-DAG:   loop.outer:

; CANONICAL-LABEL: @runtime_inclusive_cross_block_token(
; CANONICAL-NOT:   inclusive.no_wrap
; CANONICAL-NOT:   inclusive.slow
; CANONICAL-NOT:   loop.outer
; CANONICAL:       call token @llvm.coro.save
; CANONICAL:       call void @token_consume()
; CANONICAL:       call hotspotcc void @jeandle.safepoint_poll()

; CANONICAL-LABEL: @runtime_inclusive_indirectbr(
; CANONICAL-NOT:   inclusive.no_wrap
; CANONICAL-NOT:   inclusive.slow
; CANONICAL-NOT:   loop.outer
; CANONICAL:       indirectbr ptr %destination
; CANONICAL:       call hotspotcc void @jeandle.safepoint_poll()
