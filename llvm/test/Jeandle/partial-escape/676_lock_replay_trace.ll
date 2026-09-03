; RUN: opt -disable-output -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-trace-pea %s 2>&1 | FileCheck %s --check-prefix=TRACE
; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s -o %t
; RUN: FileCheck %s --check-prefix=PLACEMENT < %t
; RUN: not grep '!jeandle[.]pea[.]replay' %t

; The structured LockReplay trace describes the physical replay plan consumed
; by the transform. It covers a single replay, a same-site interleaved cascade,
; and mutually exclusive predecessor plans for one logical merge consumer.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @trace_single_replay() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 10101 to ptr), i32 16, i1 false)
       to label %body unwind label %unwind
body:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock)
  call void @sink(ptr addrspace(1) %o)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; TRACE: PEA: LockReplay function=@trace_single_replay logical_escape=[[SINGLE_LOGICAL:[0-9]+]] batch=[[SINGLE_BATCH:[0-9]+]] source=[[SINGLE_SOURCE:[0-9]+]] receiver_vo=[[SINGLE_VO:[0-9]+]] depth=0 ordinal=0

define void @trace_same_site_cascade() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %la0 = alloca i64, align 8
  %lb1 = alloca i64, align 8
  %la2 = alloca i64, align 8
  %lc3 = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 20101 to ptr), i32 16, i1 false)
       to label %alloc.b unwind label %unwind
alloc.b:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 20102 to ptr), i32 16, i1 false)
       to label %alloc.c unwind label %unwind
alloc.c:
  %c = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 20103 to ptr), i32 16, i1 false)
       to label %body unwind label %unwind
body:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %la0)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %b, ptr %lb1)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %la2)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %c, ptr %lc3)
  call void @sink(ptr addrspace(1) %c)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %c, ptr %lc3)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %la2)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %b, ptr %lb1)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %la0)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; One physical batch is globally depth-sorted. The repeated receiver VO at
; depths 0 and 2 proves receiver identity independently of emitted SSA names.
; TRACE: PEA: LockReplay function=@trace_same_site_cascade logical_escape=[[CASCADE_LOGICAL:[0-9]+]] batch=[[CASCADE_BATCH:[0-9]+]] source=[[CASCADE_SOURCE:[0-9]+]] receiver_vo=[[CASCADE_A:[0-9]+]] depth=0 ordinal=0
; TRACE-NEXT: PEA: LockReplay function=@trace_same_site_cascade logical_escape=[[CASCADE_LOGICAL]] batch=[[CASCADE_BATCH]] source=[[CASCADE_SOURCE]] receiver_vo=[[CASCADE_B:[0-9]+]] depth=1 ordinal=1
; TRACE-NEXT: PEA: LockReplay function=@trace_same_site_cascade logical_escape=[[CASCADE_LOGICAL]] batch=[[CASCADE_BATCH]] source=[[CASCADE_SOURCE]] receiver_vo=[[CASCADE_A]] depth=2 ordinal=2
; TRACE-NEXT: PEA: LockReplay function=@trace_same_site_cascade logical_escape=[[CASCADE_LOGICAL]] batch=[[CASCADE_BATCH]] source=[[CASCADE_SOURCE]] receiver_vo=[[CASCADE_C:[0-9]+]] depth=3 ordinal=3

define void @trace_alternative_predecessors(i1 %choose,
                                             ptr addrspace(1) %guard)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %left.lock = alloca i64, align 8
  %left.guard = alloca i64, align 8
  %right.outer = alloca i64, align 8
  %right.inner = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 30101 to ptr), i32 16, i1 false)
       to label %branch unwind label %unwind
branch:
  br i1 %choose, label %left, label %right
left:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %guard, ptr %left.guard)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %left.lock)
  br label %merge
right:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %right.outer)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %right.inner)
  br label %merge
merge:
  call void @sink(ptr addrspace(1) %o)
  br i1 %choose, label %left.exit, label %right.exit
left.exit:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %left.lock)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %guard, ptr %left.guard)
  ret void
right.exit:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %right.inner)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %right.outer)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The two predecessor plans have one logical consumer and one receiver VO, but
; distinct consecutive physical batches and sources. The analyzer visits the
; right path first; ordinals restart in the later left-path batch, proving
; there is no cross-path lock mixing.
; TRACE: PEA: LockReplay function=@trace_alternative_predecessors logical_escape=[[#ALT_LOGICAL:]]
; TRACE-SAME: batch=[[#ALT_FIRST_BATCH:]]
; TRACE-SAME: source=[[#ALT_FIRST_SOURCE:]]
; TRACE-SAME: receiver_vo=[[#ALT_VO:]] depth=0 ordinal=0
; TRACE-NEXT: PEA: LockReplay function=@trace_alternative_predecessors logical_escape=[[#ALT_LOGICAL]] batch=[[#ALT_FIRST_BATCH]] source=[[#ALT_FIRST_SOURCE]] receiver_vo=[[#ALT_VO]] depth=1 ordinal=1
; TRACE-NEXT: PEA: LockReplay function=@trace_alternative_predecessors logical_escape=[[#ALT_LOGICAL]] batch=[[#ALT_FIRST_BATCH+1]] source=[[#ALT_FIRST_SOURCE+1]] receiver_vo=[[#ALT_VO]] depth=1 ordinal=0

; A single predecessor can feed two independent merge consumers. Here %p
; contributes locked %x to %merge.m, while it also contributes field-only %y
; to %merge.n. %q is the other virtual predecessor that contributes the same
; locked %x to %merge.m; %real.m makes %x materialized on the third arm. The
; common monitorenter and the path-local monitorexits keep every dynamic path
; balanced.
;
; Both Materialize effects at %p physically replay before the same terminator,
; but the lockless %y effect for %merge.n must not change %x's lock provenance:
; the %p and %q LockReplay rows for %merge.m need one logical_escape.
define void @trace_mixed_consumers_same_site(i2 %path, i1 %p.to.m, i32 %v)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %x.lock = alloca i64, align 8
  %x = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 40101 to ptr), i32 16, i1 false)
       to label %alloc.y unwind label %unwind
alloc.y:
  %y = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 40102 to ptr), i32 16, i1 false)
       to label %locked unwind label %unwind
locked:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %x, ptr %x.lock)
  switch i2 %path, label %p [
    i2 1, label %q
    i2 2, label %real.m
    i2 3, label %real.n
  ]
p:
  %p.y.slot = getelementptr inbounds i8, ptr addrspace(1) %y, i64 8
  store atomic i32 %v, ptr addrspace(1) %p.y.slot unordered, align 4
  br i1 %p.to.m, label %merge.m, label %merge.n
q:
  br label %merge.m
real.m:
  call void @sink(ptr addrspace(1) %x)
  br label %merge.m
real.n:
  %real.y.slot = getelementptr inbounds i8, ptr addrspace(1) %y, i64 8
  store atomic i32 42, ptr addrspace(1) %real.y.slot unordered, align 4
  call void @sink(ptr addrspace(1) %y)
  br label %merge.n
merge.m:
  call void @sink(ptr addrspace(1) %x)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %x, ptr %x.lock)
  ret void
merge.n:
  call void @sink(ptr addrspace(1) %y)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %x, ptr %x.lock)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; %real.m's direct escape is the first lock replay. The following two rows are
; the %p and %q predecessor plans for %merge.m. Although %p's physical batch
; also contains %y's lockless materialization for %merge.n, that effect must
; not replace the lock-contributing logical consumer. Batch ordinals remain
; physical-batch-wide and restart at zero for both predecessor plans.
; TRACE: PEA: LockReplay function=@trace_mixed_consumers_same_site logical_escape=[[MIXED_DIRECT_LOGICAL:[0-9]+]] batch=[[#MIXED_DIRECT_BATCH:]]
; TRACE-SAME: source=[[MIXED_DIRECT_SOURCE:[0-9]+]] receiver_vo=[[MIXED_X:[0-9]+]] depth=0 ordinal=0
; TRACE-NEXT: PEA: LockReplay function=@trace_mixed_consumers_same_site logical_escape=[[MIXED_M_LOGICAL:[0-9]+]] batch=[[#MIXED_P_BATCH:MIXED_DIRECT_BATCH+1]]
; TRACE-SAME: source=[[MIXED_P_SOURCE:[0-9]+]] receiver_vo=[[MIXED_X]] depth=0 ordinal=0
; TRACE-NEXT: PEA: LockReplay function=@trace_mixed_consumers_same_site logical_escape=[[MIXED_M_LOGICAL]] batch=[[#MIXED_Q_BATCH:MIXED_DIRECT_BATCH+2]]
; TRACE-SAME: source=[[MIXED_Q_SOURCE:[0-9]+]] receiver_vo=[[MIXED_X]] depth=0 ordinal=0

; Two distinct locked objects can also materialize for two different merge
; consumers reached from one multi-successor predecessor. Both monitorenters
; are in the common dominator, and each terminal arm contains the corresponding
; reverse-order exits, so the shape is balanced on every dynamic path.
define void @trace_multiple_lock_consumers_same_site(i2 %path, i1 %p.to.n)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %x.lock = alloca i64, align 8
  %y.lock = alloca i64, align 8
  %x = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 50101 to ptr), i32 16, i1 false)
       to label %alloc.y unwind label %unwind
alloc.y:
  %y = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 50102 to ptr), i32 16, i1 false)
       to label %locked unwind label %unwind
locked:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %x, ptr %x.lock)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %y, ptr %y.lock)
  switch i2 %path, label %p [
    i2 1, label %q
    i2 2, label %real.m
    i2 3, label %real.n
  ]
p:
  ; Successor order makes RPO process merge.m before merge.n. That first
  ; records x's M edge plan; N later records y's distinct edge plan.
  br i1 %p.to.n, label %merge.n, label %merge.m
q:
  br label %merge.m
real.m:
  call void @sink(ptr addrspace(1) %x)
  br label %merge.m
real.n:
  call void @sink(ptr addrspace(1) %y)
  br label %merge.n
merge.m:
  call void @sink(ptr addrspace(1) %x)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %y, ptr %y.lock)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %x, ptr %x.lock)
  ret void
merge.n:
  call void @sink(ptr addrspace(1) %y)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %y, ptr %y.lock)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %x, ptr %x.lock)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The first three rows are the two-lock %real.n batch and the one-lock
; %real.m batch. The following %q batch contributes x to %merge.m. The two
; outgoing edges from %p have distinct physical batches: p->merge.m replays x,
; while p->merge.n replays the required x,y cascade. The %q and p->merge.m x
; associations share one logical ID; p->merge.n has the other consumer ID.
; TRACE: PEA: LockReplay function=@trace_multiple_lock_consumers_same_site logical_escape=[[MC_REAL_N:[0-9]+]] batch=[[#MC_FIRST_BATCH:]]
; TRACE-SAME: source=[[MC_REAL_N_SOURCE:[0-9]+]] receiver_vo=[[MC_X:[0-9]+]] depth=0 ordinal=0
; TRACE-NEXT: PEA: LockReplay function=@trace_multiple_lock_consumers_same_site logical_escape=[[MC_REAL_N]] batch=[[#MC_FIRST_BATCH]] source=[[MC_REAL_N_SOURCE]] receiver_vo=[[MC_Y:[0-9]+]] depth=1 ordinal=1
; TRACE-NEXT: PEA: LockReplay function=@trace_multiple_lock_consumers_same_site logical_escape=[[MC_REAL_M:[0-9]+]] batch=[[#MC_REAL_M_BATCH:MC_FIRST_BATCH+1]]
; TRACE-SAME: source=[[MC_REAL_M_SOURCE:[0-9]+]] receiver_vo=[[MC_X]] depth=0 ordinal=0
; TRACE-NEXT: PEA: LockReplay function=@trace_multiple_lock_consumers_same_site logical_escape=[[MC_M:[0-9]+]] batch=[[#MC_Q_BATCH:MC_FIRST_BATCH+2]]
; TRACE-SAME: source=[[MC_Q_SOURCE:[0-9]+]] receiver_vo=[[MC_X]] depth=0 ordinal=0
; TRACE-NEXT: PEA: LockReplay function=@trace_multiple_lock_consumers_same_site logical_escape=[[MC_M]] batch=[[#MC_P_BATCH:MC_FIRST_BATCH+3]]
; TRACE-SAME: source=[[MC_P_SOURCE:[0-9]+]] receiver_vo=[[MC_X]] depth=0 ordinal=0
; TRACE-NEXT: PEA: LockReplay function=@trace_multiple_lock_consumers_same_site logical_escape=[[MC_N:[0-9]+]] batch=[[#MC_N_BATCH:MC_P_BATCH+1]]
; TRACE-SAME: source=[[MC_N_SOURCE:[0-9]+]] receiver_vo=[[MC_X]] depth=0 ordinal=0
; TRACE-NEXT: PEA: LockReplay function=@trace_multiple_lock_consumers_same_site logical_escape=[[MC_N]] batch=[[#MC_N_BATCH]] source=[[MC_N_SOURCE]] receiver_vo=[[MC_Y]] depth=1 ordinal=1

; The two physical batches recorded for %p must also be consumed on their
; respective outgoing edges. Nothing is replayed unconditionally in %p:
; p->merge.m acquires only x, while p->merge.n acquires x then y.
; PLACEMENT-LABEL: define void @trace_multiple_lock_consumers_same_site(
; PLACEMENT-LABEL: p:
; PLACEMENT: br i1 %p.to.n, label %[[N_EDGE:[-A-Za-z$._0-9]+]], label %[[M_EDGE:[-A-Za-z$._0-9]+]]
; PLACEMENT: [[M_EDGE]]:
; PLACEMENT-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %x, ptr %x.lock)
; PLACEMENT-NOT: ptr addrspace(1) %y
; PLACEMENT-NEXT: br label %merge.m
; PLACEMENT: [[N_EDGE]]:
; PLACEMENT-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %x, ptr %x.lock)
; PLACEMENT-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %y, ptr %y.lock)
; PLACEMENT-NEXT: br label %merge.n

!java-method-compilation = !{}
