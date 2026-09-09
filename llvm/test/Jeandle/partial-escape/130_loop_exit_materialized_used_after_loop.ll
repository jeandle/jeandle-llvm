; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Alloc BEFORE the loop, materialized INSIDE the loop body (via @sink that
; flows to the latch), then the same pointer is used AFTER the loop. Loop-body
; partial escape retains the source OrigAlloc, replays its field before the
; escape, and both the in-loop escape and post-loop use read that single
; dominating pointer.
;
; Verifies the post-loop use sees the single materialized pointer.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare void @ret_use(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_a6_mat_in_loop_use_after(i32 %n, i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %prep unwind label %u
prep:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %x, ptr addrspace(1) %s unordered, align 4
  br label %loop
loop:
  %i = phi i32 [ 0, %prep ], [ %i1, %body ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  call void @sink(ptr addrspace(1) %o)
  %i1 = add i32 %i, 1
  br label %loop
exit:
  call void @ret_use(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The source allocation is the only invoke; both consumers receive it.
; CHECK-LABEL: define void @test_a6_mat_in_loop_use_after
; CHECK: %[[ORIG:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK-NOT: @jeandle.new_instance
; CHECK: store atomic i32 %x, ptr addrspace(1) %{{.*}}
; CHECK: call void @sink(ptr addrspace(1) %[[ORIG]])
; CHECK: call void @ret_use(ptr addrspace(1) %[[ORIG]])

!java-method-compilation = !{}
