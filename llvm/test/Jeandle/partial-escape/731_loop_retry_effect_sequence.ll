; REQUIRES: asserts
; RUN: opt -disable-output -verify-each -jeandle-trace-pea \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s 2>&1 | FileCheck %s

; The first body pass materializes both pre-loop locked objects.  The post-body
; header merge keeps predecessor effects outside LoopBlocks, while the next
; fixpoint pass creates fresh effects.  Sequence numbers consumed by surviving
; effects must not be reused across rollback; otherwise both materialize
; effects at one physical lock site can identify themselves as the batch tail.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
    ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
    ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @loop_retry_effect_sequence(i32 %n)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %la = alloca i64, align 8
  %lb = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 73101 to ptr), i32 16, i1 false)
       to label %new.b unwind label %unwind
new.b:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 73102 to ptr), i32 16, i1 false)
       to label %preheader unwind label %unwind
preheader:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %la)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %b, ptr %lb)
  br label %header
header:
  %i = phi i32 [ 0, %preheader ], [ %next, %latch ]
  %more = icmp slt i32 %i, %n
  br i1 %more, label %body, label %exit
body:
  call void @sink(ptr addrspace(1) %b)
  br label %latch
latch:
  %next = add i32 %i, 1
  br label %header
exit:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %b, ptr %lb)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %la)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A surviving plan has one physical replay batch and one strictly ordered
; pair.  The effect trace exposes the globally unique sequence assigned to
; each final effect; the transform's debug checks additionally require one
; tail emitter.
; CHECK: PEA: Materialize function=@loop_retry_effect_sequence [VO=[[A:[0-9]+]]]{{.*}} seq=[[SA:[0-9]+]]
; CHECK: PEA: Materialize function=@loop_retry_effect_sequence [VO=[[C:[0-9]+]]]{{.*}} seq=[[SB:[0-9]+]]
; CHECK: PEA: LockReplay function=@loop_retry_effect_sequence logical_escape=[[L:[0-9]+]] batch=[[B:[0-9]+]] source=[[S:[0-9]+]] receiver_vo=[[A]] depth=0 ordinal=0
; CHECK-NEXT: PEA: LockReplay function=@loop_retry_effect_sequence logical_escape=[[L]] batch=[[B]] source=[[S]] receiver_vo=[[C]] depth=1 ordinal=1
; CHECK-NOT: PEA: LockReplay function=@loop_retry_effect_sequence

!java-method-compilation = !{}
