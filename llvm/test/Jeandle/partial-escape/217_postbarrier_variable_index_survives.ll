; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform,insert-gc-barriers" -jeandle-vm-callback-log=%S/Inputs/217_postbarrier_variable_index_survives.cblog %s | FileCheck %s

; A variable-index store keeps the array real. InsertGCBarriers protects the
; retained store with a pre barrier. Its null value needs no post barrier.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc void @jeandle.pre_barrier(ptr addrspace(1))
declare hotspotcc void @jeandle.post_barrier(ptr addrspace(1), ptr addrspace(1))

declare i32 @__gxx_personality_v0(...)

define void @test_postbarrier_variable_index_survives(i64 %i) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 8888 to ptr), i32 4, i32 32, i32 16, i32 1048576)
         to label %n unwind label %u
n:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %pi = getelementptr inbounds ptr addrspace(1), ptr addrspace(1) %base, i64 %i
  store atomic ptr addrspace(1) null, ptr addrspace(1) %pi unordered, align 4
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_postbarrier_variable_index_survives
; CHECK: jeandle.new_array
; CHECK: jeandle.pre_barrier
; CHECK: store atomic
; CHECK-NOT: jeandle.post_barrier
; CHECK: ret void

!java-method-compilation = !{}
