; REQUIRES: asserts
; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:     -jeandle-pea-loop-cutoff=1 %s | FileCheck %s --check-prefix=IR
; RUN: opt -disable-output -passes="require<partial-escape-analysis>" \
; RUN:     -jeandle-pea-loop-cutoff=1 -stats %s 2>&1 | FileCheck %s --check-prefix=STATS
; RUN: opt -disable-output -jeandle-trace-pea \
; RUN:     -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:     -jeandle-pea-loop-cutoff=1 %s 2>&1 | FileCheck %s --check-prefix=TRACE

; STOP_NEW overflow escalation inside a NESTED loop structure.
;
; A 2-deep loop nest (hdr1 outer, hdr2 inner). A pre-loop virtual object
; escapes via @sink in the OUTER loop body (body1). With
; -jeandle-pea-loop-cutoff=1 the nest's max depth (2) exceeds the cutoff, so the
; outermost processLoop enters Mode::StopNewInLoopNest for the whole nest. The
; escape in body1 (processed at depth==1, in STOP_NEW) polls OverflowFlag, which
; the depth==1 processLoop catches and recovers via snapshot-restore + preheader
; drain + MATERIALIZE_ALL redo. The inner loop (hdr2) is still processed by the
; recursive processLoop during the body pass — this validates that nesting is
; handled and that the overflow/escalation machinery composes with recursive
; sub-loop dispatch.
;
; (Escapes inside the INNER / depth>1 body cannot be tested yet: pre-loop
; virtuals do not survive into nested-loop bodies in Jeandle — the loop-body
; partial-escape feature is deferred. So depth>1 overflow PROPAGATION, while
; implemented, is not exercised here.)

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_overflow_nested_outer_body(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %pre = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
          to label %e.cont unwind label %u
e.cont:
  %f = getelementptr inbounds i8, ptr addrspace(1) %pre, i64 8
  store atomic i32 42, ptr addrspace(1) %f unordered, align 4
  br label %hdr1

hdr1:
  %i1 = phi i32 [0, %e.cont], [%inc1, %latch1]
  %c1 = icmp slt i32 %i1, %n
  br i1 %c1, label %body1, label %exit1
body1:
  call void @sink(ptr addrspace(1) %pre)
  br label %hdr2

hdr2:
  %i2 = phi i32 [0, %body1], [%inc2, %latch2]
  %c2 = icmp slt i32 %i2, %n
  br i1 %c2, label %body2, label %latch1
body2:
  br label %latch2
latch2:
  %inc2 = add i32 %i2, 1
  br label %hdr2
latch1:
  %inc1 = add i32 %i1, 1
  br label %hdr1

exit1:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; IR-LABEL: define void @test_overflow_nested_outer_body
; IR: invoke {{.*}}@jeandle.new_instance({{.*}}i64 7777
; IR: call void @sink

; The nest escalated to MATERIALIZE_ALL via the STOP_NEW overflow:
; STATS: partial-escape-analysis - Regular -> MaterializeAll mode flips (escalations)
; The final recovered plan replays at the outer-loop preheader.
; TRACE: PEA: Materialize function=@test_overflow_nested_outer_body [VO=0] block=%e.cont target=

!java-method-compilation = !{}
