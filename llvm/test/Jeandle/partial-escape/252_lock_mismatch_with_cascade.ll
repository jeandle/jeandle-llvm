; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -disable-output -jeandle-trace-pea \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=TRACE

; Lock-mismatch on A across a diamond, with two objects (A and B) live.
;
;   then: monitorenter(B) then monitorenter(A) — both tracked virtually.
;   else: two external padding monitors.
;   merge: lock counts on A disagree (1 vs 0); lock counts on B disagree
;          (1 vs 0).
; Both arms therefore enter the merge at scalar depth two, then release the
; selected inner and outer owners in reverse order.
;
; Neither object is materialized per pred: the ORIGINAL allocations
; (OrigAlloc %oA and OrigAlloc %oB) dominate every use and are kept verbatim.
; Both surviving monitorenters stay in their original block, receivers
; pointing at their own OrigAlloc. No additional allocation invoke or
; materialized-object PHI is emitted for either object; owner PHIs are used
; only by the balancing exits.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare i32 @__gxx_personality_v0(...)

define void @test_lock_mismatch_with_cascade(i1 %c,
    ptr addrspace(1) %pad0, ptr addrspace(1) %pad1) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock_b = alloca i64, align 8
  %lock_a = alloca i64, align 8
  %pad0.lock = alloca i64, align 8
  %pad1.lock = alloca i64, align 8
  %oA = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
       to label %allocB unwind label %u
allocB:
  %oB = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
       to label %branch unwind label %u
branch:
  br i1 %c, label %then, label %else
then:
  tail call hotspotcc void @jeandle.monitorenter_with_thin_lock(
              ptr addrspace(1) %oB, ptr %lock_b)
  tail call hotspotcc void @jeandle.monitorenter_with_thin_lock(
              ptr addrspace(1) %oA, ptr %lock_a)
  br label %merge
else:
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(
              ptr addrspace(1) %pad0, ptr %pad0.lock)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(
              ptr addrspace(1) %pad1, ptr %pad1.lock)
  br label %merge
merge:
  %held.inner = phi ptr addrspace(1) [ %oA, %then ], [ %pad1, %else ]
  %held.inner.lock = phi ptr [ %lock_a, %then ], [ %pad1.lock, %else ]
  %held.outer = phi ptr addrspace(1) [ %oB, %then ], [ %pad0, %else ]
  %held.outer.lock = phi ptr [ %lock_b, %then ], [ %pad0.lock, %else ]
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(
              ptr addrspace(1) %held.inner, ptr %held.inner.lock)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(
              ptr addrspace(1) %held.outer, ptr %held.outer.lock)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_lock_mismatch_with_cascade
; Both ORIGINAL allocation invokes are RETAINED as the only allocations.
; CHECK: %oA = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
; CHECK: %oB = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
; No second materialization invoke is emitted.
; CHECK-NOT: pea.mat = invoke
; Each virtual source is a tail call, while its canonical replay is bare and
; keeps B-before-A ordering.
; CHECK-NOT: tail call hotspotcc void @jeandle.monitorenter_with_thin_lock
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %oB, ptr %lock_b)
; CHECK: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) %oA, ptr %lock_a)
; TRACE: PEA: LockReplay function=@test_lock_mismatch_with_cascade

!java-method-compilation = !{}
