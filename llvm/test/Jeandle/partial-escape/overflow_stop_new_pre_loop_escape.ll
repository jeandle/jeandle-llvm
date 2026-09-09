; REQUIRES: asserts
; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:     -jeandle-pea-loop-cutoff=0 %s | FileCheck %s --check-prefix=IR
; RUN: opt -disable-output -passes="require<partial-escape-analysis>" \
; RUN:     -jeandle-pea-loop-cutoff=0 -stats %s 2>&1 | FileCheck %s --check-prefix=STATS
; RUN: opt -disable-output -jeandle-trace-pea \
; RUN:     -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:     -jeandle-pea-loop-cutoff=0 %s 2>&1 | FileCheck %s --check-prefix=TRACE

; STOP_NEW overflow escalation.
;
; A pre-loop virtual object (allocated + field-stored before the loop) escapes
; via @sink inside the loop body. With -jeandle-pea-loop-cutoff=0 the loop
; (depth 1) enters Mode::StopNewInLoopNest. The in-body escape calls
; ensureMaterialized on the (necessarily outer-scope) virtual under STOP_NEW,
; which polls OverflowFlag — the Jeandle (-fno-exceptions) equivalent of an
; overflow exception. The outermost (depth==1) processLoop catches it, restores
; the snapshot, drains the preheader (processStateBeforeLoopOnOverflow), and
; redoes the body in MATERIALIZE_ALL.
;
; The escalation statistic proves that STOP_NEW overflow recovery ran. The
; final effect trace pins replay to the loop preheader, while the IR check
; confirms that replay retains the one original allocation.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_overflow_pre_loop_escape(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %pre = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
          to label %e.cont unwind label %u
e.cont:
  %f = getelementptr inbounds i8, ptr addrspace(1) %pre, i64 8
  store atomic i32 42, ptr addrspace(1) %f unordered, align 4
  br label %hdr

hdr:
  %i = phi i32 [0, %e.cont], [%inc, %latch]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  call void @sink(ptr addrspace(1) %pre)
  br label %latch
latch:
  %inc = add i32 %i, 1
  br label %hdr

exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The pre-loop object is materialized (invoke survives); @sink observes it.
; IR-LABEL: define void @test_overflow_pre_loop_escape
; IR: invoke {{.*}}@jeandle.new_instance({{.*}}i64 7777
; IR: call void @sink

; The recovered plan is created by the explicit preheader force-drain, not by
; the later header merge repairing a still-virtual preheader contribution.
; STATS: partial-escape-analysis - Materializations at loop preheader (force-drain)
; STATS-NOT: partial-escape-analysis - Materializations triggered by state merge
; The STOP_NEW overflow fired and escalated the loop to MATERIALIZE_ALL:
; STATS: partial-escape-analysis - Regular -> MaterializeAll mode flips (escalations)
; TRACE: PEA: Materialize function=@test_overflow_pre_loop_escape [VO=0] block=%e.cont target=

!java-method-compilation = !{}
