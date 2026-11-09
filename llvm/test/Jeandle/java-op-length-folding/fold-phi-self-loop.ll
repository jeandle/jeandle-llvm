; RUN: opt -S -passes=java-op-length-folding -verify-each %s | FileCheck %s

; Cycle patterns that still fold:
;  - self-edge phi: p = phi(alloc, p) — the self-edge adds no value.
;  - pure mutual cycle with a single allocation: a = phi(alloc, b);
;    b = phi(a) — the cycle back-edge contributes NoInfo, alloc wins.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)

declare i32 @__gxx_personality_v0(...)

define i32 @test_self_loop(i32 %n, i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 %n, i32 44, i32 16, i32 1048576, i1 false, i1 false)
        to label %loop unwind label %u
loop:
  %p = phi ptr addrspace(1) [ %a0, %entry ], [ %p, %loop ]
  br i1 %c, label %loop, label %exit
exit:
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %p)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @test_mutual_pure_cycle(i32 %n, i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a0 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
           ptr inttoptr (i64 12345 to ptr), i32 %n, i32 44, i32 16, i32 1048576, i1 false, i1 false)
        to label %h unwind label %u
h:
  %a = phi ptr addrspace(1) [ %a0, %entry ], [ %b, %l ]
  br i1 %c, label %l, label %exit
l:
  %b = phi ptr addrspace(1) [ %a, %h ]
  br label %h
exit:
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %a)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_self_loop
; CHECK-NOT: jeandle.arraylength
; CHECK: ret i32 %n

; CHECK-LABEL: define i32 @test_mutual_pure_cycle
; CHECK-NOT: jeandle.arraylength
; CHECK: ret i32 %n

!java-method-compilation = !{}
