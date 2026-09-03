; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Loop-body partial escape, Case A: object allocated BEFORE the loop escapes
; inside the loop body via a call that FLOWS TO THE LATCH (the escape block is
; a loop block). Jeandle retains OrigAlloc and replays its field before the
; escape; the same dominating pointer reaches the post-loop consumer.
;
; This test asserts that exactly one allocation survives and both consumers
; use it.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare void @ret_use(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_loopbody_escape_to_latch(i32 %n, i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
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

; CHECK-LABEL: define void @test_loopbody_escape_to_latch
; Exactly ONE allocation: the source %o.
; CHECK: %o = invoke hotspotcc{{.*}}@jeandle.new_instance(
; CHECK-NOT: @jeandle.new_instance
; Both the in-loop escape and the post-loop use receive OrigAlloc.
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK: call void @ret_use(ptr addrspace(1) %o)

!java-method-compilation = !{}
