; RUN: opt -S -passes=java-op-length-folding -verify-each %s | FileCheck %s

; Conflict patterns that must NOT fold:
;  - phi of two new_arrays with different constant lengths.
;  - mutual cycle hiding a different length: a = phi(alloc10, b);
;    b = phi(a, alloc20) — at runtime a CAN be the 20-array, so the
;    cycle back-edge must not be treated as "no information" alone.
;  - phi with an undef incoming.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)

declare i32 @__gxx_personality_v0(...)

define i32 @test_phi_diff_const(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %t, label %f
t:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 10, i32 56, i32 16, i32 1048576, i1 false, i1 false)
        to label %m unwind label %u
f:
  %a1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 20, i32 96, i32 16, i32 1048576, i1 false, i1 false)
        to label %m unwind label %u
m:
  %p = phi ptr addrspace(1) [ %a0, %t ], [ %a1, %f ]
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %p)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @test_mutual_cycle_conflict(i1 %c0, i1 %c1) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %x = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
          ptr inttoptr (i64 12345 to ptr), i32 10, i32 56, i32 16, i32 1048576, i1 false, i1 false)
       to label %d unwind label %u
d:
  br i1 %c0, label %h, label %g
g:
  %y = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
          ptr inttoptr (i64 12345 to ptr), i32 20, i32 96, i32 16, i32 1048576, i1 false, i1 false)
       to label %l unwind label %u
h:
  %a = phi ptr addrspace(1) [ %x, %d ], [ %b, %l ]
  br i1 %c1, label %l, label %exit
l:
  %b = phi ptr addrspace(1) [ %a, %h ], [ %y, %g ]
  br label %h
exit:
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @test_phi_undef(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %t, label %m
t:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 10, i32 56, i32 16, i32 1048576, i1 false, i1 false)
        to label %m unwind label %u
m:
  %p = phi ptr addrspace(1) [ %a0, %t ], [ undef, %entry ]
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %p)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_phi_diff_const
; CHECK: %len = call hotspotcc i32 @jeandle.arraylength

; CHECK-LABEL: define i32 @test_mutual_cycle_conflict
; CHECK: %len = call hotspotcc i32 @jeandle.arraylength

; CHECK-LABEL: define i32 @test_phi_undef
; CHECK: %len = call hotspotcc i32 @jeandle.arraylength

!java-method-compilation = !{}
