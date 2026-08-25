; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -disable-output -jeandle-trace-pea \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=TRACE

; Lock-cascade merge under the reuse-OrigAlloc model. Two preds join at
; %merge with lock counts 0 (left) and 1 (right) on the same virtual object
; -- a lock disagreement that requires the merge to reconcile per-pred object
; state.
; The left arm holds an external padding monitor, so both CFG edges have depth
; one even though their virtual-object states disagree.
;
; Under reuse-OrigAlloc the original allocation invoke (%o) is the SINGLE
; retained value: it dominates both preds and the merge. The right-arm lock
; (LC=1) is already on %o in the IR, so no additional allocation or
; materialized-object PHI is needed.
; The return consumes OrigAlloc directly. (Field-value PHIs would still be
; built here for genuine per-offset field disagreements, but this scenario
; has none.)

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @test_merge_cascade_per_pred_phi(
    i1 %c, ptr addrspace(1) %pad)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %pad.lock = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %branch unwind label %u
branch:
  br i1 %c, label %left, label %right
left:
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(
              ptr addrspace(1) %pad, ptr %pad.lock)
  br label %merge
right:
  tail call hotspotcc void @jeandle.monitorenter_with_thin_lock(
              ptr addrspace(1) %o, ptr %lock)
  br label %merge
merge:
  %held = phi ptr addrspace(1) [ %pad, %left ], [ %o, %right ]
  %held.lock = phi ptr [ %pad.lock, %left ], [ %lock, %right ]
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(
              ptr addrspace(1) %held, ptr %held.lock)
  ret ptr addrspace(1) %o
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @test_merge_cascade_per_pred_phi
; Exactly one allocation invoke (the original, retained) for the whole fn.
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
; CHECK-NOT: invoke hotspotcc{{.*}}@jeandle.new_instance
; The single right-arm lock is re-emitted on OrigAlloc %o; no additional
; allocation is introduced.
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %o, ptr %lock)
; CHECK-NOT: tail call hotspotcc void @jeandle.monitorenter_with_thin_lock
; No materialized-object PHI and no critical-edge split: the return consumes
; OrigAlloc directly. (A bare CHECK-NOT: %pea.mat would false-match the
; replay slot %pea.matslot, so assert on the invoke form and on crit.split.)
; CHECK-NOT: pea.mat = invoke
; CHECK-NOT: pea.crit.split
; CHECK: ret ptr addrspace(1) %o
; TRACE: PEA: LockReplay function=@test_merge_cascade_per_pred_phi

!java-method-compilation = !{}
