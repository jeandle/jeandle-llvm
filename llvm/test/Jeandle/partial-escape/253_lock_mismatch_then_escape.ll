; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -disable-output -jeandle-trace-pea \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=TRACE

; Lock-count mismatch with a post-merge escape.
;
;   then: monitorenter(o) tracked virtually — LockCount[o]=1.
;   else: an external padding lock — LockCount[o]=0.
;   merge: counts disagree; the object escapes via sink(o).
; Both paths hold one scalar monitor at the merge; the selected owner is
; released after the lock-state merge and escape have been observed.
;
; The lock-count mismatch does not drive a per-pred materialization cascade.
; The ORIGINAL allocation (OrigAlloc %o) is kept alive (it dominates the
; escape point), the single surviving monitorenter stays in its original
; block with receiver OrigAlloc, and the post-merge sink receives OrigAlloc
; directly. No additional allocation invoke is emitted and no
; materialized-object PHI is built at the merge. A small owner PHI selects
; the balanced monitor exit required by the two source paths.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_lock_mismatch_then_escape(i1 %c, ptr addrspace(1) %pad) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
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
  call void @sink(ptr addrspace(1) %o)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(
              ptr addrspace(1) %held, ptr %held.lock)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_lock_mismatch_then_escape
; The original allocation invoke is RETAINED as the sole allocation.
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
; No second materialization invoke is emitted.
; CHECK-NOT: pea.mat = invoke
; The single surviving monitorenter stays in its original block, receiver
; OrigAlloc %o.
; CHECK-NOT: tail call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %o, ptr %lock)
; The sink receives OrigAlloc directly.
; CHECK: call void @sink(ptr addrspace(1) %o)
; The source was a tail call, so this bare call proves replay occurred.
; TRACE: PEA: LockReplay function=@test_lock_mismatch_then_escape

!java-method-compilation = !{}
