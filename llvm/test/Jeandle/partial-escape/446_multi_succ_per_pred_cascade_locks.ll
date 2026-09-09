; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -disable-output -jeandle-trace-pea \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=TRACE

; Multi-successor lock-carrying pred under the reuse-OrigAlloc model.
; `right` holds enters on %a (depth 0) and %b (depth 1) and has TWO successor
; merges (merge1, merge2), both mixed. The left arm holds two external padding
; monitors, so every incoming edge has scalar depth two while the virtual lock
; states still differ. The a.f=b field store is tracked, and
; materializing a cascades b (forward prerequisite).
;
; A per-pred materialize whose captured lock stack is NON-EMPTY takes the
; shared-flip (Case-A) path: the first merge's processing flips
; BlockExits[right] to materialized (ensureMaterialized at
; the pred's end), so the second merge sees %a/%b already materialized and
; does NOT re-capture the same lock stack. The dedup is keyed per
; (pred, object): keying it per (pred, TARGET MERGE) would let each merge
; capture the SAME stack and re-acquire every lock TWICE on every path out
; of `right` (la,la,lb,lb). Each lock is re-emitted exactly once (la then
; lb, strictly increasing depth). The padding-only left arm keeps the
; per-pred path; its two per-merge effects replay the a.f=b store at left's
; terminator twice — idempotent, harmless. Each merge releases its selected
; inner and outer owners.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_multi_succ_per_pred_cascade_locks(
    i1 %c, i1 %c2, i1 %c3,
    ptr addrspace(1) %pad0, ptr addrspace(1) %pad1)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %la = alloca i64, align 8
  %lb = alloca i64, align 8
  %pad0.lock = alloca i64, align 8
  %pad1.lock = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
          ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
       to label %na unwind label %u
na:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
          ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
       to label %fld unwind label %u
fld:
  ; a.f = b: materializing a per-pred cascades b (forward prereq).
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 0
  store atomic ptr addrspace(1) %b, ptr addrspace(1) %af unordered, align 8
  br i1 %c, label %left, label %right
left:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %pad0, ptr %pad0.lock)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %pad1, ptr %pad1.lock)
  br i1 %c3, label %merge1, label %merge2
right:
  tail call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %la)
  tail call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %b, ptr %lb)
  br i1 %c2, label %merge1, label %merge2
merge1:
  %held1.inner = phi ptr addrspace(1) [ %pad1, %left ], [ %b, %right ]
  %held1.inner.lock = phi ptr [ %pad1.lock, %left ], [ %lb, %right ]
  %held1.outer = phi ptr addrspace(1) [ %pad0, %left ], [ %a, %right ]
  %held1.outer.lock = phi ptr [ %pad0.lock, %left ], [ %la, %right ]
  call void @sink(ptr addrspace(1) %a)
  call void @sink(ptr addrspace(1) %b)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %held1.inner, ptr %held1.inner.lock)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %held1.outer, ptr %held1.outer.lock)
  ret void
merge2:
  %held2.inner = phi ptr addrspace(1) [ %pad1, %left ], [ %b, %right ]
  %held2.inner.lock = phi ptr [ %pad1.lock, %left ], [ %lb, %right ]
  %held2.outer = phi ptr addrspace(1) [ %pad0, %left ], [ %a, %right ]
  %held2.outer.lock = phi ptr [ %pad0.lock, %left ], [ %la, %right ]
  call void @sink(ptr addrspace(1) %a)
  call void @sink(ptr addrspace(1) %b)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %held2.inner, ptr %held2.inner.lock)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %held2.outer, ptr %held2.outer.lock)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_multi_succ_per_pred_cascade_locks
; Both original allocation invokes are retained (a, then b).
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
; No additional allocation invokes anywhere.
; CHECK-NOT: pea.mat = invoke
; The a.f=b field store is replayed onto OrigAlloc %a with OrigAlloc %b (twice
; on the lock-free left arm — idempotent per-merge replay — once on right).
; CHECK: store atomic ptr addrspace(1) %b, ptr addrspace(1) %{{.*}} unordered, align 8
; The right arm re-emits each virtual enter EXACTLY ONCE onto OrigAlloc
; %a/%b (shared-flip: the second merge sees the VO already materialized).
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %a, ptr %la)
; CHECK-NOT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %a, ptr %la)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %b, ptr %lb)
; CHECK-NOT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %b, ptr %lb)
; CHECK-NOT: poison
; CHECK-NOT: pea.crit.split
; CHECK: ret void
; CHECK-NOT: tail call hotspotcc void @jeandle.monitorenter_with_lightweight_lock
; TRACE: PEA: LockReplay function=@test_multi_succ_per_pred_cascade_locks

!java-method-compilation = !{}
