; RUN: opt -S -jeandle-trace-pea -jeandle-dump-pea-stats -passes="require<partial-escape-analysis>,partial-escape-transform,insert-gc-barriers" %s 2>&1 | FileCheck %s --check-prefixes=TRACE,CHECK

; Storing a virtual instance into a real array makes the value escape.
; InsertGCBarriers must protect the retained store using the real value.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.pre_barrier(ptr addrspace(1))
declare hotspotcc void @jeandle.post_barrier(ptr addrspace(1), ptr addrspace(1))

declare i32 @__gxx_personality_v0(...)

define void @test_postbarrier_nonvirtual_addr_survives(ptr addrspace(1) %arr) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %v = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5555 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %p2 = getelementptr inbounds ptr addrspace(1), ptr addrspace(1) %base, i64 2
  store atomic ptr addrspace(1) %v, ptr addrspace(1) %p2 unordered, align 4
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The escaping value must remain a real object for the store and barrier.
; TRACE: PEA: EliminateAllocation function=@test_postbarrier_nonvirtual_addr_survives [VO=0]
; TRACE: PEA: Materialize function=@test_postbarrier_nonvirtual_addr_survives [VO=0]
; TRACE: PEA stats @test_postbarrier_nonvirtual_addr_survives: NeverEscapes=0 PartiallyEscapes=1 AlwaysEscapes=0
; CHECK-LABEL: define void @test_postbarrier_nonvirtual_addr_survives
; CHECK: jeandle.new_instance
; CHECK: store atomic
; CHECK: jeandle.post_barrier

!java-method-compilation = !{}
