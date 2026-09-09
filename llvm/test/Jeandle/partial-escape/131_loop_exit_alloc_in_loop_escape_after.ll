; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Alloc INSIDE the loop body, escape AFTER the loop exit. The body alloc
; is tracked through the back-edge, and the post-loop @sink call
; changes the object to materialized state. OrigAlloc stays at its source
; position and is the pointer observed after the loop.
;
; Pre-LCSSA, the original IR uses %o directly in the exit block: the
; body block dominates the exit (single-pred exit from body). After
; materialization, the exit use remains %o; dominance is preserved by the
; original SSA shape.
;
; This exercises the "alloc-in-loop + escape-after-loop" path.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_a6_alloc_in_loop_use_after(i32 %n, i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %i1, %cont ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit_null
body:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %st unwind label %u
st:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %x, ptr addrspace(1) %s unordered, align 4
  %ce = icmp eq i32 %i, 7
  br i1 %ce, label %exit_use, label %cont
cont:
  %i1 = add i32 %i, 1
  br label %loop
exit_use:
  ; Post-loop use of the retained body-local OrigAlloc.
  call void @sink(ptr addrspace(1) %o)
  ret void
exit_null:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The field store is replayed onto OrigAlloc and @sink receives %o. Exactly one
; new_instance invoke survives, with no separate preheader allocation.
; CHECK-LABEL: define void @test_a6_alloc_in_loop_use_after
; CHECK: %[[ORIG:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK-NOT: @jeandle.new_instance
; CHECK: store atomic i32 %x, ptr addrspace(1) %{{.*}}
; CHECK: call void @sink(ptr addrspace(1) %[[ORIG]])

!java-method-compilation = !{}
