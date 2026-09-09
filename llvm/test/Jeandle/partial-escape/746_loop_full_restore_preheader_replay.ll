; REQUIRES: asserts
; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-pea-loop-fixpoint-max-iters=1 \
; RUN:   -jeandle-pea-analyze-function=full_restore_field_replay \
; RUN:   %s | FileCheck %s --check-prefix=FIELD-IR
; RUN: opt -disable-output -verify-each -jeandle-trace-pea \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-pea-loop-fixpoint-max-iters=1 \
; RUN:   -jeandle-pea-analyze-function=full_restore_field_replay \
; RUN:   %s 2>&1 | FileCheck %s --check-prefix=FIELD-TRACE
; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-pea-loop-fixpoint-max-iters=1 \
; RUN:   -jeandle-pea-analyze-function=full_restore_lock_replay \
; RUN:   %s | FileCheck %s --check-prefix=LOCK-IR
; RUN: opt -disable-output -verify-each -jeandle-trace-pea \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-pea-loop-fixpoint-max-iters=1 \
; RUN:   -jeandle-pea-analyze-function=full_restore_lock_replay \
; RUN:   %s 2>&1 | FileCheck %s --check-prefix=LOCK-TRACE
; RUN: not --crash opt -disable-output \
; RUN:   -passes="require<partial-escape-analysis>" \
; RUN:   -jeandle-pea-loop-fixpoint-max-iters=0 %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=BAD-CAP

; A one-pass cap deterministically abandons the Regular attempt after its
; first B != B' transition.  The header pointer PHI makes that transition
; materialize the forward virtual on the canonical preheader edge.  Full
; recovery must discard that failed-attempt replay before its block-end drain
; emits the sole surviving replay.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void
@jeandle.monitorenter_with_thin_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void
@jeandle.monitorexit_with_thin_lock(ptr addrspace(1), ptr) nounwind

define void @full_restore_field_replay(i1 %done)
    gc "hotspotgc" personality ptr null {
entry:
  %object = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74601 to ptr), i32 16, i1 false)
  %field = getelementptr i8, ptr addrspace(1) %object, i64 8
  store atomic i32 42, ptr addrspace(1) %field unordered, align 4
  br label %loop.preheader

loop.preheader:
  br label %loop.header

loop.header:
  %carried = phi ptr addrspace(1) [ %object, %loop.preheader ],
                                  [ null, %loop.latch ]
  br i1 %done, label %exit, label %loop.latch

loop.latch:
  br label %loop.header

exit:
  ret void
}

define void @full_restore_lock_replay(i1 %done)
    gc "hotspotgc" personality ptr null {
entry:
  %lock = alloca i64, align 8
  %object = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74602 to ptr), i32 16, i1 false)
  call hotspotcc void @jeandle.monitorenter_with_thin_lock(
      ptr addrspace(1) %object, ptr %lock)
  %field = getelementptr i8, ptr addrspace(1) %object, i64 8
  store atomic i32 84, ptr addrspace(1) %field unordered, align 4
  br label %loop.preheader

loop.preheader:
  br label %loop.header

loop.header:
  %carried = phi ptr addrspace(1) [ %object, %loop.preheader ],
                                  [ null, %loop.latch ]
  br i1 %done, label %exit, label %loop.latch

loop.latch:
  br label %loop.header

exit:
  call hotspotcc void @jeandle.monitorexit_with_thin_lock(
      ptr addrspace(1) %object, ptr %lock)
  ret void
}

; FIELD-IR-LABEL: define void @full_restore_field_replay(
; FIELD-IR: call hotspotcc ptr addrspace(1) @jeandle.new_instance
; FIELD-IR-COUNT-1: store atomic i32 42,
; FIELD-IR-NOT: store atomic i32 42
; FIELD-IR: ret void

; FIELD-TRACE-LABEL: PEA: EliminateAllocation function=@full_restore_field_replay
; FIELD-TRACE-COUNT-1: PEA: Materialize function=@full_restore_field_replay [VO=0] block=%loop.preheader
; FIELD-TRACE-NOT: PEA: Materialize function=@full_restore_field_replay [VO=0]

; LOCK-IR-LABEL: define void @full_restore_lock_replay(
; LOCK-IR: [[LOCKED:%.*]] = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; LOCK-IR-COUNT-1: store atomic i32 84,
; LOCK-IR-NOT: store atomic i32 84
; LOCK-IR-COUNT-1: call hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) [[LOCKED]], ptr %lock)
; LOCK-IR-NOT: call hotspotcc void @jeandle.monitorenter_with_thin_lock
; LOCK-IR: call hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) [[LOCKED]], ptr %lock)

; LOCK-TRACE-LABEL: PEA: EliminateAllocation function=@full_restore_lock_replay
; LOCK-TRACE-COUNT-1: PEA: Materialize function=@full_restore_lock_replay [VO=0] block=%loop.preheader
; LOCK-TRACE-NOT: PEA: Materialize function=@full_restore_lock_replay [VO=0]
; LOCK-TRACE-COUNT-1: PEA: LockReplay function=@full_restore_lock_replay logical_escape=0 batch=0 source=0 receiver_vo=0 depth=0 ordinal=0
; LOCK-TRACE-NOT: PEA: LockReplay function=@full_restore_lock_replay

; BAD-CAP: LLVM ERROR: -jeandle-pea-loop-fixpoint-max-iters must be at least 1

!java-method-compilation = !{}
