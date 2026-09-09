; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -disable-output -jeandle-trace-pea \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=TRACE

; PEA Case C lock-mismatch — diamond CFG, both arms allocate the same Klass,
; but the left arm enters a monitor on its alloc (live lock count = 1 at
; pred exit) while the right arm does not (lock count = 0). The lock-state
; compatibility check in synthesizeCaseC fails, so Case C is rejected and
; the analyzer falls through to Case A — both virtuals materialize at their
; respective predecessor terminators by retaining each OrigAlloc and replaying
; its state there. (Strict lock order cascade applies on the left, but since
; there's only one locked virtual, no extra cascade.)
;
; Expected: both source allocations survive in IR; the LLVM PHI also survives,
; merging the two OrigAlloc values.
; The right arm holds an external padding monitor, giving both incoming edges
; scalar depth one; the merged held owner is released after the sink.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_casec_lock_mismatch(i1 %c, ptr addrspace(1) %pad)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %pad.lock = alloca i64, align 8
  br i1 %c, label %left, label %right
left:
  %o1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %lcont unwind label %u
lcont:
  ; Enter monitor on the left arm so left.LockCount == 1 at exit.
  tail call hotspotcc void @jeandle.monitorenter_with_thin_lock(
                ptr addrspace(1) %o1, ptr %lock)
  br label %merge
right:
  %o2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %rcont unwind label %u
rcont:
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(
                ptr addrspace(1) %pad, ptr %pad.lock)
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %o1, %lcont ], [ %o2, %rcont ]
  %held = phi ptr addrspace(1) [ %o1, %lcont ], [ %pad, %rcont ]
  %held.lock = phi ptr [ %lock, %lcont ], [ %pad.lock, %rcont ]
  call void @sink(ptr addrspace(1) %p)
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(
                ptr addrspace(1) %held, ptr %held.lock)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Lock mismatch -> Case A fall-through -> both arms materialize at preds.
; CHECK-LABEL: define void @test_casec_lock_mismatch
; CHECK: invoke hotspotcc {{.*}}@jeandle.new_instance
; CHECK: invoke hotspotcc {{.*}}@jeandle.new_instance
; CHECK: phi ptr addrspace(1)
; CHECK: call void @sink
; CHECK-NOT: tail call hotspotcc void @jeandle.monitorenter_with_thin_lock
; TRACE: PEA: LockReplay function=@test_casec_lock_mismatch

!java-method-compilation = !{}
