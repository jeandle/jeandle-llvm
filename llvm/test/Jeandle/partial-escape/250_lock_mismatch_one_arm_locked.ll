; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -disable-output -jeandle-trace-pea \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=TRACE

; Lock-count mismatch at a merge.
;
; entry: alloc o (virtual). branch on %c.
; then: monitorenter(o) — tracked virtually, LockCount[o]=1 at then exit.
; else: an external padding monitor — LockCount[o]=0 at else exit.
; merge: counts disagree.
; Both arms have scalar CFG depth one and the merged owner is released before
; return, so the function is balanced independently of the PEA object state.
;
; The lock-count mismatch does not drive a per-pred materialization cascade:
; the ORIGINAL allocation (OrigAlloc %o) dominates every escape point and
; every use, so it is kept verbatim and the tail-marked source enter is
; replaced by a canonical bare replay on OrigAlloc. No additional allocation
; invoke or materialized-object PHI is emitted; the owner PHI exists only to
; release the path-selected real monitor.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare i32 @__gxx_personality_v0(...)

define void @test_lock_mismatch_one_arm_locked(i1 %c, ptr addrspace(1) %pad) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %pad.lock = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %branch unwind label %u
branch:
  br i1 %c, label %then, label %else
then:
  tail call hotspotcc void @jeandle.monitorenter_with_thin_lock(
              ptr addrspace(1) %o, ptr %lock)
  br label %merge
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
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_lock_mismatch_one_arm_locked
; The original allocation invoke is RETAINED as the sole allocation.
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
; No second materialization invoke is emitted.
; CHECK-NOT: pea.mat = invoke
; The canonical replay uses OrigAlloc %o.
; CHECK-NOT: tail call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %o, ptr %lock)
; The source was a tail call, so this bare call proves replay occurred.
; TRACE: PEA: LockReplay function=@test_lock_mismatch_one_arm_locked

!java-method-compilation = !{}
