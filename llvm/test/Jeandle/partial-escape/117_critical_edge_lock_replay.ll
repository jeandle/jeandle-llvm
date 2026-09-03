; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -disable-output -jeandle-trace-pea \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=TRACE

; Lock replay on a critical predecessor.
;
; The virtual-object lock state differs across the two incoming paths. PEA
; retains the original allocation and re-emits the required monitorenter on
; that same %o receiver. Replay placement remains edge-sensitive: a
; predecessor with another successor must not leak merge-only lock effects
; onto the cold path. The verifier and trace checks cover the normalized
; replay plan; no new allocation is created at the merge.
;
; The else arm holds an external padding monitor so both incoming CFG depths
; are one. The virtual-object lock state still differs across the merge, and
; both dynamic paths release exactly the monitor they acquired.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare i32 @__gxx_personality_v0(...)

define void @critical_edge_lock_mismatch(i1 %c1, i1 %c2,
    ptr addrspace(1) %pad)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %pad.lock = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %branch unwind label %u
branch:
  br i1 %c1, label %then, label %else
then:
  tail call hotspotcc void @jeandle.monitorenter_with_thin_lock(
              ptr addrspace(1) %o, ptr %lock)
  ; Critical edge: `then` has two successors, `merge` has two preds.
  br i1 %c2, label %merge, label %cold
else:
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(
              ptr addrspace(1) %pad, ptr %pad.lock)
  br label %merge
merge:
  %held = phi ptr addrspace(1) [ %o, %then ], [ %pad, %else ]
  %held.lock = phi ptr [ %lock, %then ], [ %pad.lock, %else ]
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(
              ptr addrspace(1) %held, ptr %held.lock)
  ret void
cold:
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(
              ptr addrspace(1) %o, ptr %lock)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The original allocation is the sole receiver allocation. The lock mismatch
; must re-emit a real enter for %o without creating another new_instance.
; CHECK-LABEL: define void @critical_edge_lock_mismatch
; CHECK: %o = invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: tail call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %o,
; TRACE: PEA: LockReplay function=@critical_edge_lock_mismatch

!java-method-compilation = !{}
