; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Multiple back-edges (two latches) feeding one loop header — a legal LLVM
; IR shape no existing test covered. A pre-loop virtual object's field
; (offset 8) is loop-carried: preheader stores 1, the body stores the
; induction %i, and BOTH latches branch back to the header. The header
; merge therefore has THREE predecessors (preheader + latch1 + latch2).
;
; The header's merged state B must merge all three predecessors' field
; states; the per-offset field-PHI's back-edge incoming must agree across
; both latches (both observe the body's store of %i). Convergence is on
; the stable header merged state. The alloc + stores + load are eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_multi_latch_carried(i32 %n, i1 %d) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 41001 to ptr), i32 16, i1 false)
       to label %prep unwind label %u
prep:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 1, ptr addrspace(1) %s unordered, align 4
  br label %loop
loop:
  %i = phi i32 [ 0, %prep ], [ %i1, %latch1 ], [ %i2, %latch2 ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  store atomic i32 %i, ptr addrspace(1) %s unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  call void @use(i32 %v)
  br i1 %d, label %latch1, label %latch2
latch1:
  %i1 = add i32 %i, 1
  br label %loop
latch2:
  %i2 = add i32 %i, 2
  br label %loop
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both latches contribute the same back-edge field value (%i); the field-PHI
; merges all three incomings and the alloc + stores + load are eliminated.
; CHECK-LABEL: define void @test_multi_latch_carried
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: call void @use(i32 %i)

!java-method-compilation = !{}
