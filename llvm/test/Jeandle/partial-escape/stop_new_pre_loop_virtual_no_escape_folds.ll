; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:     -jeandle-pea-loop-cutoff=0 %s | FileCheck %s

; StopNew tracks existing virtuals (StopNew != MaterializeAll).
;
; With -jeandle-pea-loop-cutoff=0 the single loop (depth 1) enters
; Mode::StopNewInLoopNest. A pre-loop virtual object (allocated and field-stored
; before the loop) is only LOADED inside the body — it never escapes.
; StopNewInLoopNest suppresses NEW virtualizations but keeps
; tracking already-virtual objects (loads/stores/merges proceed as in Regular).
; Jeandle matches this: the load folds to the stored constant and the object is
; eliminated. Crucially, the in-body load is NOT a materialization, so the
; overflow check (ensureMaterialized under STOP_NEW) does NOT fire and the nest
; is NOT escalated to MATERIALIZE_ALL — if it were, the object would survive
; materialized instead of being eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_stop_new_tracks_virtual(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
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
  %v = load atomic i32, ptr addrspace(1) %f unordered, align 4
  call void @use(i32 %v)
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

; The object is eliminated and the load folds to the stored constant 42;
; no allocation survives (i.e. StopNew did NOT escalate to MATERIALIZE_ALL,
; which would have materialized it).
; CHECK-LABEL: define void @test_stop_new_tracks_virtual
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: load atomic
; CHECK: call void @use(i32 42)

!java-method-compilation = !{}
