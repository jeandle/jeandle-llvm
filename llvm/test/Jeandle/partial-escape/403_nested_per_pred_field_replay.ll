; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -disable-output -jeandle-trace-pea \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=TRACE

; Nested per-pred materialization under the reuse-OrigAlloc model. `outer`
; (11111) is virtual on both merge preds with lock counts 0 (left) / 1
; (right) -- a lock mismatch -- AND outer.field (offset 8) holds a SECOND
; virtual object `inner` (22222).
;
; The original allocation invokes (%outer, %inner) are both retained and
; dominate every escape. The right-arm monitorenter is re-emitted onto %outer
; in `right`, and the outer.f=inner field store is replayed onto %outer (with
; %inner as the value) at each materialization point (left and right). No
; additional allocation, materialized-object PHI, or critical-edge split is
; needed. The escape consumes %outer directly.
; The left arm holds an external padding monitor and the merged owner is
; released after the sink, keeping both CFG paths balanced at scalar depth one.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_nested_per_pred_field_replay(
    i1 %c, ptr addrspace(1) %pad)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %pad.lock = alloca i64, align 8
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
           to label %oi unwind label %u
oi:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
           to label %fld unwind label %u
fld:
  %ofs = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %ofs unordered, align 8
  br label %branch
branch:
  br i1 %c, label %left, label %right
left:
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(
              ptr addrspace(1) %pad, ptr %pad.lock)
  br label %merge
right:
  tail call hotspotcc void @jeandle.monitorenter_with_thin_lock(
              ptr addrspace(1) %outer, ptr %lock)
  br label %merge
merge:
  %held = phi ptr addrspace(1) [ %pad, %left ], [ %outer, %right ]
  %held.lock = phi ptr [ %pad.lock, %left ], [ %lock, %right ]
  call void @sink(ptr addrspace(1) %outer)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(
              ptr addrspace(1) %held, ptr %held.lock)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_nested_per_pred_field_replay
; Both original allocation invokes are retained (outer, then inner).
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
; No additional allocation invokes and no critical-edge splits anywhere.
; CHECK-NOT: pea.mat = invoke
; CHECK-NOT: pea.crit.split
; The outer.f=inner field store is replayed onto OrigAlloc %outer with %inner
; as the value, and the right-arm lock is re-emitted on %outer.
; CHECK: getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
; CHECK: store atomic ptr addrspace(1) %inner, ptr addrspace(1) %{{.*}} unordered, align 8
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %outer, ptr %lock)
; CHECK-NOT: tail call hotspotcc void @jeandle.monitorenter_with_thin_lock
; The escape (merge sink) consumes OrigAlloc %outer directly.
; CHECK: call void @sink(ptr addrspace(1) %outer)
; TRACE: PEA: LockReplay function=@test_nested_per_pred_field_replay

!java-method-compilation = !{}
