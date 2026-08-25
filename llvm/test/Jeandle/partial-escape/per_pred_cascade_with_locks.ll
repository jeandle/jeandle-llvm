; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -disable-output -jeandle-trace-pea \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=TRACE

; Per-pred replay of a CYCLIC field graph, under the reuse-OrigAlloc model.
; `o` is virtual on both merge preds with lock counts 0 (left) / 1 (right) — a
; lock mismatch — while the left arm holds an external padding monitor, so
; both CFG depths are one. `o` and `p` form a cycle: o.f = p, p.g = o. The mismatch
; drives per-pred replay of the field stores at BOTH preds, but under
; reuse-OrigAlloc neither object is re-materialized: the ORIGINAL allocations
; (OrigAlloc %o and OrigAlloc %p) are both KEPT (no new allocation invokes) and
; each replayed field store uses OrigAlloc as its value. The back edge p.g = o
; resolves to OrigAlloc %o (no poison). The virtual source enter is replayed
; as a canonical bare call, and the selected held owner is released after the
; merge sinks.
; See PartialEscapeTransform.cpp applyMaterialize (cyclic-field-materialize).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @per_pred_cascade_with_locks(i1 %c, ptr addrspace(1) %pad)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %pad.lock = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 11111 to ptr), i32 16, i1 false) to label %oi unwind label %u
oi:
  %p = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 22222 to ptr), i32 16, i1 false) to label %fld unwind label %u
fld:
  %of = getelementptr inbounds i8, ptr addrspace(1) %o, i64 0
  store atomic ptr addrspace(1) %p, ptr addrspace(1) %of unordered, align 8
  %pg = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  store atomic ptr addrspace(1) %o, ptr addrspace(1) %pg unordered, align 8
  br i1 %c, label %left, label %right
left:
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(
      ptr addrspace(1) %pad, ptr %pad.lock)
  br label %merge
right:
  tail call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %o, ptr %lock)
  br label %merge
merge:
  %held = phi ptr addrspace(1) [ %pad, %left ], [ %o, %right ]
  %held.lock = phi ptr [ %pad.lock, %left ], [ %lock, %right ]
  call void @sink(ptr addrspace(1) %o)
  call void @sink(ptr addrspace(1) %p)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(
      ptr addrspace(1) %held, ptr %held.lock)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}

; CHECK-LABEL: define void @per_pred_cascade_with_locks
; Both ORIGINAL allocation invokes are RETAINED.
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
; CHECK: %p = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
; Materialization emits no new allocation invoke.
; CHECK-NOT: pea.mat = invoke
; Per-pred replayed field stores use OrigAlloc as the stored value (the cycle
; back-edge p.g = o resolves to OrigAlloc %o, never poison). Two stores per
; pred: left emits both forward and back edges, right emits both too.
; CHECK: store atomic ptr addrspace(1) %o, ptr addrspace(1) %pea.matslot{{[0-9]*}} unordered, align 8
; CHECK: store atomic ptr addrspace(1) %p, ptr addrspace(1) %pea.matslot{{[0-9]*}} unordered, align 8
; CHECK: store atomic ptr addrspace(1) %o, ptr addrspace(1) %pea.matslot{{[0-9]*}} unordered, align 8
; CHECK: store atomic ptr addrspace(1) %p, ptr addrspace(1) %pea.matslot{{[0-9]*}} unordered, align 8
; CHECK-NOT: poison
; Exactly one canonical replay targets OrigAlloc %o.
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %o, ptr %lock)
; No duplicate replay targets %o.
; CHECK-NOT: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; Sinks at merge receive OrigAlloc directly rather than a materialized-object
; PHI; the owner PHI is used only by the balancing monitor exit.
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK: call void @sink(ptr addrspace(1) %p)
; CHECK: ret void
; CHECK-NOT: tail call hotspotcc void @jeandle.monitorenter_with_thin_lock
; TRACE: PEA: LockReplay function=@per_pred_cascade_with_locks
