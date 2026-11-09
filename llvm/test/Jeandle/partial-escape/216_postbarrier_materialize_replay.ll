; RUN: opt -S -jeandle-trace-pea -jeandle-dump-pea-stats -passes="require<partial-escape-analysis>,partial-escape-transform,insert-gc-barriers" -jeandle-vm-callback-log=%S/Inputs/216_postbarrier_materialize_replay.cblog %s 2>&1 | FileCheck %s --check-prefixes=TRACE,CHECK

; A virtual Object[] escapes through an opaque sink. PEA replays its nested
; reference store into the retained allocation. InsertGCBarriers runs after
; PEA and must protect that replayed store before publication to the sink.

@arrayOopDesc.element_size.object = private constant i32 8

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.pre_barrier(ptr addrspace(1))
declare hotspotcc void @jeandle.post_barrier(ptr addrspace(1), ptr addrspace(1))

declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_postbarrier_materialize_replay() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 8888 to ptr), i32 4, i32 48, i32 16, i32 1048576, i1 false, i1 false)
         to label %n1 unwind label %u
n1:
  %v = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5555 to ptr), i32 16, i1 false)
       to label %n2 unwind label %u
n2:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %p2 = getelementptr inbounds ptr addrspace(1), ptr addrspace(1) %base, i64 2
  store atomic ptr addrspace(1) %v, ptr addrspace(1) %p2 unordered, align 8
  call void @sink(ptr addrspace(1) %arr)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; TRACE: PEA: EliminateStore function=@test_postbarrier_materialize_replay [VO=0]
; TRACE-DAG: PEA: Materialize function=@test_postbarrier_materialize_replay [VO=0]
; TRACE-DAG: PEA: Materialize function=@test_postbarrier_materialize_replay [VO=1]
; TRACE: PEA stats @test_postbarrier_materialize_replay: NeverEscapes=0 PartiallyEscapes=2 AlwaysEscapes=0
; CHECK-LABEL: define void @test_postbarrier_materialize_replay
; Both allocations materialize (the nested oop materializes first, before the
; array it is stored into; order is not significant).
; CHECK-DAG: jeandle.new_array
; CHECK-DAG: jeandle.new_instance
; The replayed store into the materialized array must appear.
; CHECK: jeandle.pre_barrier
; CHECK: store atomic
; CHECK: jeandle.post_barrier
; CHECK: call void @sink
; No duplicate barrier is needed after publication to the sink.
; CHECK-NOT: jeandle.post_barrier

!java-method-compilation = !{}
