; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Loop with TWO exit blocks. The alloc happens before the loop (entry →
; prep, where prep is the unique loop-preheader so the loop fixpoint
; runs). Inside the loop body, the alloc escapes via @sink on every
; iteration, so PEA retains OrigAlloc %o. Both exit blocks (one reached via
; the !c branch from the header, one via a break inside the body) read the
; same dominating source pointer; no per-exit allocation or
; materialized-object PHI is needed.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare void @ret_use_a(ptr addrspace(1))
declare void @ret_use_b(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_a6_multiple_exits(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %prep unwind label %u
prep:
  br label %loop
loop:
  %i = phi i32 [ 0, %prep ], [ %i1, %cont ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit_a
body:
  call void @sink(ptr addrspace(1) %o)
  %i1 = add i32 %i, 1
  %brk = icmp eq i32 %i, 7
  br i1 %brk, label %exit_b, label %cont
cont:
  br label %loop
exit_a:
  call void @ret_use_a(ptr addrspace(1) %o)
  ret void
exit_b:
  call void @ret_use_b(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Exactly one allocation: the original %o. Every consumer receives it.
; CHECK-LABEL: define void @test_a6_multiple_exits
; CHECK: %o = invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK-NOT: @jeandle.new_instance
; CHECK-DAG: call void @sink(ptr addrspace(1) %o)
; CHECK-DAG: call void @ret_use_a(ptr addrspace(1) %o)
; CHECK-DAG: call void @ret_use_b(ptr addrspace(1) %o)

!java-method-compilation = !{}
