; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform,insert-gc-barriers" -jeandle-vm-callback-log=%S/Inputs/214_postbarrier_virtual_array_fold.cblog %s | FileCheck %s

; Object[] holding a virtual instance. PEA eliminates both allocations and
; the reference store before InsertGCBarriers, so no barriers are needed.

@arrayOopDesc.element_size.object = private constant i32 8

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.pre_barrier(ptr addrspace(1))
declare hotspotcc void @jeandle.post_barrier(ptr addrspace(1), ptr addrspace(1))

declare i32 @__gxx_personality_v0(...)

define i32 @test_postbarrier_virtual_array_fold() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 8888 to ptr), i32 4, i32 48, i32 16, i32 1048576)
         to label %n1 unwind label %u
n1:
  %v = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5555 to ptr), i32 16, i1 false)
       to label %n2 unwind label %u
n2:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %p2 = getelementptr inbounds ptr addrspace(1), ptr addrspace(1) %base, i64 2
  store atomic ptr addrspace(1) %v, ptr addrspace(1) %p2 unordered, align 8
  ret i32 0
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_postbarrier_virtual_array_fold
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store
; CHECK-NOT: jeandle.pre_barrier
; CHECK-NOT: jeandle.post_barrier
; CHECK: ret i32 0

!java-method-compilation = !{}
