; RUN: opt -S -passes=java-op-length-folding -verify-each %s | FileCheck %s

; No fold: loop-carried phi where the back-edge allocation has a different
; length, and cycles containing an opaque source (function argument, load).

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)

declare i32 @__gxx_personality_v0(...)

define i32 @test_loop_phi_diff_length(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 10, i32 56, i32 16, i32 1048576, i1 false, i1 false)
        to label %preheader unwind label %u
preheader:
  br label %header
header:
  %p = phi ptr addrspace(1) [ %a0, %preheader ], [ %a1, %latch2 ]
  br i1 %c, label %latch, label %exit
latch:
  %a1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 20, i32 96, i32 16, i32 1048576, i1 false, i1 false)
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

define i32 @test_cycle_with_argument(ptr addrspace(1) %arg, i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 10, i32 56, i32 16, i32 1048576, i1 false, i1 false)
        to label %preheader unwind label %u
preheader:
  br label %header
header:
  %p = phi ptr addrspace(1) [ %a0, %preheader ], [ %q, %latch ]
  %q = phi ptr addrspace(1) [ %arg, %preheader ], [ %p, %latch ]
  br i1 %c, label %latch, label %exit
latch:
  br label %header
exit:
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %p)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @test_phi_with_load(ptr addrspace(1) %slot, i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 10, i32 56, i32 16, i32 1048576, i1 false, i1 false)
        to label %d unwind label %u
d:
  %loaded = load ptr addrspace(1), ptr addrspace(1) %slot
  br i1 %c, label %t, label %m
t:
  br label %m
m:
  %p = phi ptr addrspace(1) [ %a0, %t ], [ %loaded, %d ]
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %p)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_loop_phi_diff_length
; CHECK: %len = call hotspotcc i32 @jeandle.arraylength

; CHECK-LABEL: define i32 @test_cycle_with_argument
; CHECK: %len = call hotspotcc i32 @jeandle.arraylength

; CHECK-LABEL: define i32 @test_phi_with_load
; CHECK: %len = call hotspotcc i32 @jeandle.arraylength

!java-method-compilation = !{}
