; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform,insert-gc-barriers" -jeandle-vm-callback-log=%S/Inputs/219_postbarrier_phi_addr_survives.cblog %s | FileCheck %s

; A PHI merging different array klasses keeps both arrays real. The retained
; null store needs a pre barrier, and no post barrier, after PEA.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc void @jeandle.pre_barrier(ptr addrspace(1))
declare hotspotcc void @jeandle.post_barrier(ptr addrspace(1), ptr addrspace(1))

declare i32 @__gxx_personality_v0(...)

define void @test_postbarrier_phi_addr_survives(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %a, label %b
a:
  %arr1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
             ptr inttoptr (i64 8881 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
          to label %merge unwind label %u
b:
  %arr2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
             ptr inttoptr (i64 8882 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
          to label %merge unwind label %u
merge:
  %arr = phi ptr addrspace(1) [ %arr1, %a ], [ %arr2, %b ]
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %p2 = getelementptr inbounds ptr addrspace(1), ptr addrspace(1) %base, i64 2
  store atomic ptr addrspace(1) null, ptr addrspace(1) %p2 unordered, align 4
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both arrays remain real and the retained store receives its pre barrier.
; CHECK-LABEL: define void @test_postbarrier_phi_addr_survives
; CHECK: jeandle.new_array
; CHECK: jeandle.pre_barrier
; CHECK: store atomic
; CHECK-NOT: jeandle.post_barrier
; CHECK: ret void

!java-method-compilation = !{}
