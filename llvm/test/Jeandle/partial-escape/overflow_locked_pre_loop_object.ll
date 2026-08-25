; REQUIRES: asserts
; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:     -jeandle-pea-loop-cutoff=0 %s | FileCheck %s --check-prefix=IR
; RUN: opt -disable-output -passes="require<partial-escape-analysis>" \
; RUN:     -jeandle-pea-loop-cutoff=0 -stats %s 2>&1 | FileCheck %s --check-prefix=STATS
; RUN: opt -disable-output -jeandle-trace-pea \
; RUN:     -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:     -jeandle-pea-loop-cutoff=0 %s 2>&1 | FileCheck %s --check-prefix=TRACE

; STOP_NEW overflow escalation carrying a live lock.
;
; The pre-loop virtual object is monitorenter-locked before the loop, then
; escapes via @sink inside the loop body. With -jeandle-pea-loop-cutoff=0 the
; loop enters STOP_NEW; the escape polls OverflowFlag; the depth==1 processLoop
; catches it and redoes the body in MATERIALIZE_ALL after draining the
; preheader. The drain (processStateBeforeLoopOnOverflow -> materializeAt...
; -> ensureMaterialized) must capture the live lock stack into the Materialize
; effect so the re-emitted monitorenter/exit bracket the materialized object
; (materialize-commit lock capture). Validates that the overflow
; escalation composes with the lock model.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_overflow_locked(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %pre = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
          to label %e.cont unwind label %u
e.cont:
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %pre, ptr %lock)
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
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) %pre, ptr %lock)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The materialized object is bracketed by monitorenter/exit (lock captured),
; and @sink observes it.
; IR-LABEL: define void @test_overflow_locked
; IR: invoke {{.*}}@jeandle.new_instance({{.*}}i64 7777
; IR: call {{.*}}@jeandle.monitorenter_with_thin_lock
; IR: call void @sink
; IR: call {{.*}}@jeandle.monitorexit_with_thin_lock

; The final recovered plan replays fields and the captured lock at the
; preheader rather than creating another allocation in the loop.
; STATS: partial-escape-analysis - Materializations at loop preheader (force-drain)
; STATS-NOT: partial-escape-analysis - Materializations triggered by state merge
; The STOP_NEW overflow escalated the loop to MATERIALIZE_ALL:
; STATS: partial-escape-analysis - Regular -> MaterializeAll mode flips (escalations)
; TRACE: PEA: Materialize function=@test_overflow_locked [VO=0] block=%e.cont target=

!java-method-compilation = !{}
