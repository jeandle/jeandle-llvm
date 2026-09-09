; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Loop-body partial escape, NESTED loops: object allocated BEFORE the outer
; loop escapes inside the INNER loop body (the @sink call flows to the inner
; latch, so EscapeLoop = inner loop != AllocLoop = none). Jeandle retains the
; single source OrigAlloc before the outer loop. The inner-preheader replay
; produced by an intermediate nested-loop pass is cleared by the outer
; fixpoint; the surviving replay is at the outer preheader and the same
; OrigAlloc flows into the inner loop.
;
; This is the canonical "outer allocation partially escapes in inner loop"
; scenario. Soundness: exactly one allocation.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare void @ret_use(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_nested_outer_alloc_inner_escape(i32 %n, i32 %m, i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %preo unwind label %u
preo:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %x, ptr addrspace(1) %s unordered, align 4
  br label %oloop
oloop:
  %i = phi i32 [ 0, %preo ], [ %i1, %ocont ]
  %ci = icmp slt i32 %i, %n
  br i1 %ci, label %obody, label %oexit
obody:
  br label %iloop
iloop:
  %j = phi i32 [ 0, %obody ], [ %j1, %ibody ]
  %cj = icmp slt i32 %j, %m
  br i1 %cj, label %ibody, label %iexit
ibody:
  call void @sink(ptr addrspace(1) %o)
  %j1 = add i32 %j, 1
  br label %iloop
iexit:
  br label %ocont
ocont:
  %i1 = add i32 %i, 1
  br label %oloop
oexit:
  call void @ret_use(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_nested_outer_alloc_inner_escape
; Exactly ONE source allocation remains before the outer loop. Replay must not
; introduce a second allocation inside either loop.
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(
; CHECK-NOT: jeandle.new_instance
; Both the inner-loop escape and the post-loop use receive the single pointer.
; CHECK: call void @sink(ptr addrspace(1)
; CHECK: call void @ret_use(ptr addrspace(1)

!java-method-compilation = !{}
