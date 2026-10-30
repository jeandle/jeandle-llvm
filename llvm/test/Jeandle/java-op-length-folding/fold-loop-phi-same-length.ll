; RUN: opt -S -passes=java-op-length-folding -verify-each %s | FileCheck %s

; Loop-carried phi where the array is re-allocated each iteration with the
; SAME SSA length: folds. The back-edge new_array is reachable only via the
; in-progress phi, which contributes NoInfo; both allocs agree on %n.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)

declare i32 @__gxx_personality_v0(...)

define i32 @test_loop_phi_same_length(i32 %n, i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 %n, i32 44, i32 16, i32 1048576, i1 false, i1 false)
        to label %preheader unwind label %u
preheader:
  br label %header
header:
  %p = phi ptr addrspace(1) [ %a0, %preheader ], [ %a1, %latch2 ]
  br i1 %c, label %latch, label %exit
latch:
  %a1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 %n, i32 44, i32 16, i32 1048576, i1 false, i1 false)
        to label %latch2 unwind label %u
latch2:
  br label %header
exit:
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %p)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_loop_phi_same_length
; CHECK-NOT: jeandle.arraylength
; CHECK: ret i32 %n

!java-method-compilation = !{}
