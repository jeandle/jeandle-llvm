; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A loop unreachable from entry. The reachable function body just
; returns; a dead loop with an alloc + escape exists in the IR (not
; reachable via any edge from entry). The analyzer's RPO walk over the
; reachable subgraph should not crash on the dead blocks, and the dead
; loop's IR should survive untouched.
;
; The dead loop is itself a perfectly natural loop with a preheader,
; so processLoop's fixpoint COULD run on it; however, the outer RPO
; walk is rooted at entry and ReversePostOrderTraversal visits only
; reachable blocks. So PEA skips the dead loop entirely. This test
; documents that contract (dead code is ignored, no crash).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_unreachable_loop(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  ret void

dead_prep:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %dead_loop unwind label %u
dead_loop:
  %i = phi i32 [ 0, %dead_prep ], [ %i1, %dead_body ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %dead_body, label %dead_exit
dead_body:
  call void @sink(ptr addrspace(1) %o)
  %i1 = add i32 %i, 1
  br label %dead_loop
dead_exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The reachable %entry just returns. Dead-block IR survives.
; CHECK-LABEL: define void @test_unreachable_loop
; CHECK: entry:
; CHECK-NEXT: ret void
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call void @sink

!java-method-compilation = !{}
