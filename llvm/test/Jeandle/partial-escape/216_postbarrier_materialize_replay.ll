; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/216_postbarrier_materialize_replay.cblog %s | FileCheck %s

; Object[] virtual array holding a virtual oop; the array then escapes through
; an opaque @sink. Soundness of the post_barrier fold on the escape path:
; foldPostBarrier erases the original barrier (ReplaceCallEffect, ObjID =
; array), and processStore records the store into the array's field state.
; When the array escapes, PEA materializes the array (and the nested oop) and
; *replays* the store as a real atomic-unordered addrspace(1) store into the
; materialized array. The original barrier must NOT survive (it referenced the
; old virtual slot); the replayed store is picked up later by InsertGCBarriers
; (which runs after PEA) and gets a fresh post_barrier then. So in the
; PEA-transform output: the original jeandle.post_barrier is gone, both
; allocations are present (materialized), and a replayed store appears.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.post_barrier(ptr addrspace(1), ptr addrspace(1))

declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_postbarrier_materialize_replay() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 8888 to ptr), i32 4, i32 32, i32 16, i32 1048576)
         to label %n1 unwind label %u
n1:
  %v = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5555 to ptr), i32 16, i1 false)
       to label %n2 unwind label %u
n2:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %p2 = getelementptr inbounds ptr addrspace(1), ptr addrspace(1) %base, i64 2
  store atomic ptr addrspace(1) %v, ptr addrspace(1) %p2 unordered, align 4
  call hotspotcc void @jeandle.post_barrier(ptr addrspace(1) %p2,
                                           ptr addrspace(1) %v)
  call void @sink(ptr addrspace(1) %arr)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_postbarrier_materialize_replay
; Both allocations materialize (the nested oop materializes first, before the
; array it is stored into; order is not significant).
; CHECK-DAG: jeandle.new_array
; CHECK-DAG: jeandle.new_instance
; The replayed store into the materialized array must appear.
; CHECK: store atomic
; CHECK: call void @sink
; The original barrier is folded away (a fresh one is re-inserted downstream
; by InsertGCBarriers on the replayed store, not by PEA).
; CHECK-NOT: jeandle.post_barrier

!java-method-compilation = !{}
