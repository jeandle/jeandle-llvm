; RUN: opt -S -passes=java-op-length-folding -verify-each %s | FileCheck %s
; RUN: opt -S -passes='java-op-length-folding,java-op-length-folding' -verify-each %s | FileCheck %s

; Shared-subgraph memoization tests for JavaOpLengthFolding:
;  - Multi-layer shared diamonds with constant and SSA lengths fold.
;  - Shared subgraphs with conflicting lengths, unknown args, undef, or poison
;    remain conservative (no fold).
;  - Self-loops and mutual cycles preserve soundness (fold when all non-cycle
;    sources agree; no fold when a cycle hides a conflicting length).
;  - Shared subgraphs reached at different depths respect MaxResolveDepth (16)
;    regardless of branch visitation order.
;  - Non-zero and non-constant GEP wrappers stay opaque while zero-offset GEP
;    and freeze canonicalize to the shared node.
;  - Multiple queries in the same function have independent cache state.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)

declare i32 @__gxx_personality_v0(...)

define i32 @test_shared_diamond_const(i1 %c0, i1 %c1, i1 %c2, i1 %c3) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 10, i32 56, i32 16, i32 1048576, i1 false, i1 false)
        to label %b1 unwind label %u
b1:
  %a1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 10, i32 56, i32 16, i32 1048576, i1 false, i1 false)
        to label %b2 unwind label %u
b2:
  %l1_a = select i1 %c0, ptr addrspace(1) %a0, ptr addrspace(1) %a1
  %l1_b = select i1 %c1, ptr addrspace(1) %a1, ptr addrspace(1) %a0
  %l1_a_g = getelementptr i8, ptr addrspace(1) %l1_a, i32 0
  %l1_a_f = freeze ptr addrspace(1) %l1_a_g
  %l2_a = select i1 %c2, ptr addrspace(1) %l1_a, ptr addrspace(1) %l1_b
  %l2_b = select i1 %c3, ptr addrspace(1) %l1_b, ptr addrspace(1) %l1_a_f
  %l3_a = select i1 %c0, ptr addrspace(1) %l2_a, ptr addrspace(1) %l2_b
  %l3_b = select i1 %c1, ptr addrspace(1) %l2_b, ptr addrspace(1) %l2_a
  %root = select i1 %c2, ptr addrspace(1) %l3_a, ptr addrspace(1) %l3_b
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %root)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @test_shared_diamond_ssa(i32 %n, i1 %c0, i1 %c1, i1 %c2) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c0, label %t, label %f
t:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 %n, i32 44, i32 16, i32 1048576, i1 false, i1 false)
        to label %m1 unwind label %u
f:
  %a1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 %n, i32 44, i32 16, i32 1048576, i1 false, i1 false)
        to label %m1 unwind label %u
m1:
  %p = phi ptr addrspace(1) [ %a0, %t ], [ %a1, %f ]
  %p_f = freeze ptr addrspace(1) %p
  %s1 = select i1 %c1, ptr addrspace(1) %p, ptr addrspace(1) %p_f
  %s2 = select i1 %c2, ptr addrspace(1) %p_f, ptr addrspace(1) %p
  %root = select i1 %c0, ptr addrspace(1) %s1, ptr addrspace(1) %s2
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %root)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @test_shared_diamond_diff_const(i1 %c0, i1 %c1, i1 %c2) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 10, i32 56, i32 16, i32 1048576, i1 false, i1 false)
        to label %b1 unwind label %u
b1:
  %a1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 20, i32 96, i32 16, i32 1048576, i1 false, i1 false)
        to label %b2 unwind label %u
b2:
  %s0 = select i1 %c0, ptr addrspace(1) %a0, ptr addrspace(1) %a1
  %s1 = select i1 %c1, ptr addrspace(1) %s0, ptr addrspace(1) %a0
  %s2 = select i1 %c2, ptr addrspace(1) %a0, ptr addrspace(1) %s0
  %root = select i1 %c0, ptr addrspace(1) %s1, ptr addrspace(1) %s2
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %root)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @test_shared_diamond_unknown_arg(ptr addrspace(1) %ext, i1 %c0, i1 %c1) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 10, i32 56, i32 16, i32 1048576, i1 false, i1 false)
        to label %b1 unwind label %u
b1:
  %s0 = select i1 %c0, ptr addrspace(1) %a0, ptr addrspace(1) %ext
  %s1 = select i1 %c1, ptr addrspace(1) %s0, ptr addrspace(1) %a0
  %s2 = select i1 %c0, ptr addrspace(1) %a0, ptr addrspace(1) %s0
  %root = select i1 %c1, ptr addrspace(1) %s1, ptr addrspace(1) %s2
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %root)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @test_shared_diamond_undef(i1 %c0, i1 %c1) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 10, i32 56, i32 16, i32 1048576, i1 false, i1 false)
        to label %b1 unwind label %u
b1:
  %s0 = select i1 %c0, ptr addrspace(1) %a0, ptr addrspace(1) undef
  %s1 = select i1 %c1, ptr addrspace(1) %s0, ptr addrspace(1) %a0
  %s2 = select i1 %c0, ptr addrspace(1) %a0, ptr addrspace(1) %s0
  %root = select i1 %c1, ptr addrspace(1) %s1, ptr addrspace(1) %s2
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %root)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @test_shared_diamond_poison(i1 %c0, i1 %c1) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 10, i32 56, i32 16, i32 1048576, i1 false, i1 false)
        to label %b1 unwind label %u
b1:
  %s0 = select i1 %c0, ptr addrspace(1) %a0, ptr addrspace(1) poison
  %s1 = select i1 %c1, ptr addrspace(1) %s0, ptr addrspace(1) %a0
  %s2 = select i1 %c0, ptr addrspace(1) %a0, ptr addrspace(1) %s0
  %root = select i1 %c1, ptr addrspace(1) %s1, ptr addrspace(1) %s2
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %root)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @test_shared_self_and_mutual_cycle_fold(i32 %n, i1 %c0, i1 %c1, i1 %c2) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 %n, i32 44, i32 16, i32 1048576, i1 false, i1 false)
        to label %b1 unwind label %u
b1:
  %a1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 %n, i32 44, i32 16, i32 1048576, i1 false, i1 false)
        to label %b2 unwind label %u
b2:
  %s0 = select i1 %c0, ptr addrspace(1) %a0, ptr addrspace(1) %a1
  br i1 %c0, label %self_loop, label %l
self_loop:
  %self = phi ptr addrspace(1) [ %s0, %b2 ], [ %self, %self_loop ]
  br i1 %c1, label %self_loop, label %h
h:
  %a = phi ptr addrspace(1) [ %self, %self_loop ], [ %b, %l ]
  br i1 %c2, label %l, label %exit
l:
  %b = phi ptr addrspace(1) [ %a, %h ], [ %s0, %b2 ]
  br label %h
exit:
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @test_shared_cycle_hidden_conflict(i1 %c0, i1 %c1, i1 %c2) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 10, i32 56, i32 16, i32 1048576, i1 false, i1 false)
        to label %b1 unwind label %u
b1:
  %a1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 10, i32 56, i32 16, i32 1048576, i1 false, i1 false)
        to label %d unwind label %u
d:
  %s0 = select i1 %c2, ptr addrspace(1) %a0, ptr addrspace(1) %a1
  br i1 %c0, label %h, label %g
g:
  %y = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
          ptr inttoptr (i64 12345 to ptr), i32 20, i32 96, i32 16, i32 1048576, i1 false, i1 false)
       to label %l unwind label %u
h:
  %a = phi ptr addrspace(1) [ %s0, %d ], [ %b, %l ]
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

; Shallow arm visits %s_leaf at depth 1 (leaves at depth 2 <= 16), while the
; deep arm visits %s_leaf at depth 16 (leaves at depth 17 > MaxResolveDepth).
; The deep arm must NOT reuse the shallow cached entry.
define i32 @test_shared_depth_shallow_then_deep(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 10, i32 56, i32 16, i32 1048576, i1 false, i1 false)
        to label %b1 unwind label %u
b1:
  %a1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 10, i32 56, i32 16, i32 1048576, i1 false, i1 false)
        to label %b2 unwind label %u
b2:
  %s_leaf = select i1 %c, ptr addrspace(1) %a0, ptr addrspace(1) %a1
  %d1 = select i1 %c, ptr addrspace(1) %s_leaf, ptr addrspace(1) %a0
  %d2 = select i1 %c, ptr addrspace(1) %d1, ptr addrspace(1) %a0
  %d3 = select i1 %c, ptr addrspace(1) %d2, ptr addrspace(1) %a0
  %d4 = select i1 %c, ptr addrspace(1) %d3, ptr addrspace(1) %a0
  %d5 = select i1 %c, ptr addrspace(1) %d4, ptr addrspace(1) %a0
  %d6 = select i1 %c, ptr addrspace(1) %d5, ptr addrspace(1) %a0
  %d7 = select i1 %c, ptr addrspace(1) %d6, ptr addrspace(1) %a0
  %d8 = select i1 %c, ptr addrspace(1) %d7, ptr addrspace(1) %a0
  %d9 = select i1 %c, ptr addrspace(1) %d8, ptr addrspace(1) %a0
  %d10 = select i1 %c, ptr addrspace(1) %d9, ptr addrspace(1) %a0
  %d11 = select i1 %c, ptr addrspace(1) %d10, ptr addrspace(1) %a0
  %d12 = select i1 %c, ptr addrspace(1) %d11, ptr addrspace(1) %a0
  %d13 = select i1 %c, ptr addrspace(1) %d12, ptr addrspace(1) %a0
  %d14 = select i1 %c, ptr addrspace(1) %d13, ptr addrspace(1) %a0
  %d15 = select i1 %c, ptr addrspace(1) %d14, ptr addrspace(1) %a0
  %root = select i1 %c, ptr addrspace(1) %s_leaf, ptr addrspace(1) %d15
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %root)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Swapped arm order: deep arm hits MaxResolveDepth first, then a second query
; resolves %s_leaf at shallow depth and still folds.
define i32 @test_shared_depth_deep_then_shallow(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 10, i32 56, i32 16, i32 1048576, i1 false, i1 false)
        to label %b1 unwind label %u
b1:
  %a1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 10, i32 56, i32 16, i32 1048576, i1 false, i1 false)
        to label %b2 unwind label %u
b2:
  %s_leaf = select i1 %c, ptr addrspace(1) %a0, ptr addrspace(1) %a1
  %d1 = select i1 %c, ptr addrspace(1) %s_leaf, ptr addrspace(1) %a0
  %d2 = select i1 %c, ptr addrspace(1) %d1, ptr addrspace(1) %a0
  %d3 = select i1 %c, ptr addrspace(1) %d2, ptr addrspace(1) %a0
  %d4 = select i1 %c, ptr addrspace(1) %d3, ptr addrspace(1) %a0
  %d5 = select i1 %c, ptr addrspace(1) %d4, ptr addrspace(1) %a0
  %d6 = select i1 %c, ptr addrspace(1) %d5, ptr addrspace(1) %a0
  %d7 = select i1 %c, ptr addrspace(1) %d6, ptr addrspace(1) %a0
  %d8 = select i1 %c, ptr addrspace(1) %d7, ptr addrspace(1) %a0
  %d9 = select i1 %c, ptr addrspace(1) %d8, ptr addrspace(1) %a0
  %d10 = select i1 %c, ptr addrspace(1) %d9, ptr addrspace(1) %a0
  %d11 = select i1 %c, ptr addrspace(1) %d10, ptr addrspace(1) %a0
  %d12 = select i1 %c, ptr addrspace(1) %d11, ptr addrspace(1) %a0
  %d13 = select i1 %c, ptr addrspace(1) %d12, ptr addrspace(1) %a0
  %d14 = select i1 %c, ptr addrspace(1) %d13, ptr addrspace(1) %a0
  %d15 = select i1 %c, ptr addrspace(1) %d14, ptr addrspace(1) %a0
  %root = select i1 %c, ptr addrspace(1) %d15, ptr addrspace(1) %s_leaf
  %len_deep = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %root)
  %len_shallow = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %s_leaf)
  %sum = add i32 %len_deep, %len_shallow
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Deepest leaf is at exact depth 16 (== MaxResolveDepth), so folding succeeds.
define i32 @test_shared_depth_exact_16_fold(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 10, i32 56, i32 16, i32 1048576, i1 false, i1 false)
        to label %b1 unwind label %u
b1:
  %a1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 10, i32 56, i32 16, i32 1048576, i1 false, i1 false)
        to label %b2 unwind label %u
b2:
  %s_leaf = select i1 %c, ptr addrspace(1) %a0, ptr addrspace(1) %a1
  %d1 = select i1 %c, ptr addrspace(1) %s_leaf, ptr addrspace(1) %a0
  %d2 = select i1 %c, ptr addrspace(1) %d1, ptr addrspace(1) %a0
  %d3 = select i1 %c, ptr addrspace(1) %d2, ptr addrspace(1) %a0
  %d4 = select i1 %c, ptr addrspace(1) %d3, ptr addrspace(1) %a0
  %d5 = select i1 %c, ptr addrspace(1) %d4, ptr addrspace(1) %a0
  %d6 = select i1 %c, ptr addrspace(1) %d5, ptr addrspace(1) %a0
  %d7 = select i1 %c, ptr addrspace(1) %d6, ptr addrspace(1) %a0
  %d8 = select i1 %c, ptr addrspace(1) %d7, ptr addrspace(1) %a0
  %d9 = select i1 %c, ptr addrspace(1) %d8, ptr addrspace(1) %a0
  %d10 = select i1 %c, ptr addrspace(1) %d9, ptr addrspace(1) %a0
  %d11 = select i1 %c, ptr addrspace(1) %d10, ptr addrspace(1) %a0
  %d12 = select i1 %c, ptr addrspace(1) %d11, ptr addrspace(1) %a0
  %d13 = select i1 %c, ptr addrspace(1) %d12, ptr addrspace(1) %a0
  %d14 = select i1 %c, ptr addrspace(1) %d13, ptr addrspace(1) %a0
  %root = select i1 %c, ptr addrspace(1) %s_leaf, ptr addrspace(1) %d14
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %root)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @test_shared_gep_wrappers(i64 %idx, i1 %c0, i1 %c1) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 7, i32 44, i32 16, i32 1048576, i1 false, i1 false)
        to label %b1 unwind label %u
b1:
  %a1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 7, i32 44, i32 16, i32 1048576, i1 false, i1 false)
        to label %b2 unwind label %u
b2:
  %s0 = select i1 %c0, ptr addrspace(1) %a0, ptr addrspace(1) %a1
  %g_nonzero = getelementptr i8, ptr addrspace(1) %s0, i32 16
  %len_nonzero = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %g_nonzero)
  %g_nonconst = getelementptr i8, ptr addrspace(1) %s0, i64 %idx
  %len_nonconst = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %g_nonconst)
  %g_zero = getelementptr i8, ptr addrspace(1) %s0, i32 0
  %f_zero = freeze ptr addrspace(1) %g_zero
  %s1 = select i1 %c1, ptr addrspace(1) %s0, ptr addrspace(1) %f_zero
  %len_zero = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %s1)
  %t0 = add i32 %len_nonzero, %len_nonconst
  %sum = add i32 %t0, %len_zero
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @test_multiple_queries_independent(i32 %n, i1 %c0, i1 %c1) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 %n, i32 44, i32 16, i32 1048576, i1 false, i1 false)
        to label %b1 unwind label %u
b1:
  %a1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 %n, i32 44, i32 16, i32 1048576, i1 false, i1 false)
        to label %b2 unwind label %u
b2:
  %s0 = select i1 %c0, ptr addrspace(1) %a0, ptr addrspace(1) %a1
  %s1 = select i1 %c1, ptr addrspace(1) %s0, ptr addrspace(1) %a0
  %s2 = select i1 %c0, ptr addrspace(1) %a1, ptr addrspace(1) %s0
  %root = select i1 %c1, ptr addrspace(1) %s1, ptr addrspace(1) %s2
  %len1 = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %root)
  %len2 = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %s0)
  %sum = add i32 %len1, %len2
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_shared_diamond_const
; CHECK-NOT: jeandle.arraylength
; CHECK: ret i32 10

; CHECK-LABEL: define i32 @test_shared_diamond_ssa
; CHECK-NOT: jeandle.arraylength
; CHECK: ret i32 %n

; CHECK-LABEL: define i32 @test_shared_diamond_diff_const
; CHECK: %len = call hotspotcc i32 @jeandle.arraylength

; CHECK-LABEL: define i32 @test_shared_diamond_unknown_arg
; CHECK: %len = call hotspotcc i32 @jeandle.arraylength

; CHECK-LABEL: define i32 @test_shared_diamond_undef
; CHECK: %len = call hotspotcc i32 @jeandle.arraylength

; CHECK-LABEL: define i32 @test_shared_diamond_poison
; CHECK: %len = call hotspotcc i32 @jeandle.arraylength

; CHECK-LABEL: define i32 @test_shared_self_and_mutual_cycle_fold
; CHECK-NOT: jeandle.arraylength
; CHECK: ret i32 %n

; CHECK-LABEL: define i32 @test_shared_cycle_hidden_conflict
; CHECK: %len = call hotspotcc i32 @jeandle.arraylength

; CHECK-LABEL: define i32 @test_shared_depth_shallow_then_deep
; CHECK: %len = call hotspotcc i32 @jeandle.arraylength

; CHECK-LABEL: define i32 @test_shared_depth_deep_then_shallow
; CHECK: %len_deep = call hotspotcc i32 @jeandle.arraylength
; CHECK-NOT: jeandle.arraylength
; CHECK: %sum = add i32 %len_deep, 10
; CHECK: ret i32 %sum

; CHECK-LABEL: define i32 @test_shared_depth_exact_16_fold
; CHECK-NOT: jeandle.arraylength
; CHECK: ret i32 10

; CHECK-LABEL: define i32 @test_shared_gep_wrappers
; CHECK: %len_nonzero = call hotspotcc i32 @jeandle.arraylength
; CHECK: %len_nonconst = call hotspotcc i32 @jeandle.arraylength
; CHECK-NOT: jeandle.arraylength
; CHECK: %sum = add i32 %t0, 7
; CHECK: ret i32 %sum

; CHECK-LABEL: define i32 @test_multiple_queries_independent
; CHECK-NOT: jeandle.arraylength
; CHECK: %sum = add i32 %n, %n
; CHECK: ret i32 %sum

!java-method-compilation = !{}
