; RUN: opt -S -passes=java-op-length-folding -verify-each %s | FileCheck %s

; PHI of two new_arrays with the same SSA length folds; select likewise;
; nested phi-of-phi chains resolve recursively.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)

declare i32 @__gxx_personality_v0(...)

define i32 @test_phi_same_ssa(i32 %n, i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %t, label %f
t:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 %n, i32 44, i32 16, i32 1048576, i1 false, i1 false)
        to label %m unwind label %u
f:
  %a1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 %n, i32 44, i32 16, i32 1048576, i1 false, i1 false)
        to label %m unwind label %u
m:
  %p = phi ptr addrspace(1) [ %a0, %t ], [ %a1, %f ]
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %p)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @test_select_same_ssa(i32 %n, i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 %n, i32 44, i32 16, i32 1048576, i1 false, i1 false)
        to label %s1 unwind label %u
s1:
  %a1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 %n, i32 44, i32 16, i32 1048576, i1 false, i1 false)
        to label %s2 unwind label %u
s2:
  %p = select i1 %c, ptr addrspace(1) %a0, ptr addrspace(1) %a1
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %p)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @test_nested_phi(i32 %n, i1 %c1, i1 %c2) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c1, label %t, label %f
t:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 %n, i32 44, i32 16, i32 1048576, i1 false, i1 false)
        to label %m1 unwind label %u
f:
  %a1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 %n, i32 44, i32 16, i32 1048576, i1 false, i1 false)
        to label %m1 unwind label %u
m1:
  %p1 = phi ptr addrspace(1) [ %a0, %t ], [ %a1, %f ]
  br i1 %c2, label %l, label %r
l:
  %a2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 %n, i32 44, i32 16, i32 1048576, i1 false, i1 false)
        to label %m2 unwind label %u
r:
  br label %m2
m2:
  %p2 = phi ptr addrspace(1) [ %a2, %l ], [ %p1, %r ]
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %p2)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_phi_same_ssa
; CHECK-NOT: jeandle.arraylength
; CHECK: ret i32 %n

; CHECK-LABEL: define i32 @test_select_same_ssa
; CHECK-NOT: jeandle.arraylength
; CHECK: ret i32 %n

; CHECK-LABEL: define i32 @test_nested_phi
; CHECK-NOT: jeandle.arraylength
; CHECK: ret i32 %n

!java-method-compilation = !{}
