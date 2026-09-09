; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -verify-each %s -o /dev/null
; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -disable-output -jeandle-trace-pea \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=TRACE

; Case-A merge in the presence of a pre-existing PHI that names the virtual
; object's allocation on its incoming edges. The %held PHI merges the
; still-virtual %o (then arm) with the non-virtual %pad (else arm), so %o
; materializes per-pred: its original new_instance invoke is retained and
; the missing monitorenter is re-emitted (LockReplay). Because the retained
; OrigAlloc dominates the merge block, the pre-existing %pre PHI's incomings
; stay valid and need no use rewriting; %pre is later collapsed by the
; trivial-PHI fold. The -verify-each RUN line guards that this merge
; produces no SSA dominance violation.
;
; An external padding monitor on the else arm keeps the scalar CFG depth
; balanced without changing the virtual object's per-pred lock mismatch.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare i32 @__gxx_personality_v0(...)

define void @rauwphi_safe(i1 %c, ptr addrspace(1) %pad) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %pad.lock = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %branch unwind label %u
branch:
  br i1 %c, label %then, label %else
then:
  ; The source tail marker distinguishes this enter from a canonical replay.
  tail call hotspotcc void @jeandle.monitorenter_with_thin_lock(
              ptr addrspace(1) %o, ptr %lock)
  br label %merge
else:
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(
              ptr addrspace(1) %pad, ptr %pad.lock)
  br label %merge
merge:
  ; Pre-existing PHI naming OrigAlloc on both incoming preds. OrigAlloc is
  ; retained and dominates the merge, so both incomings remain valid with
  ; no rewriting; the trivial-PHI fold later collapses this PHI to %o.
  %pre = phi ptr addrspace(1) [ %o, %then ], [ %o, %else ]
  %held = phi ptr addrspace(1) [ %o, %then ], [ %pad, %else ]
  %held.lock = phi ptr [ %lock, %then ], [ %pad.lock, %else ]
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(
              ptr addrspace(1) %held, ptr %held.lock)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Round-trips through opt -verify-each — a malformed PHI would abort the
; verifier and FileCheck would never see the label. The transformation
; itself is verified by the first RUN line; this FileCheck is just a smoke
; test that the lock-mismatch replay retains the original allocation invoke
; and re-emits the monitorenter as a plain (non-tail) call.
; CHECK-LABEL: define void @rauwphi_safe
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK-NOT: tail call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; TRACE: PEA: LockReplay function=@rauwphi_safe

!java-method-compilation = !{}
