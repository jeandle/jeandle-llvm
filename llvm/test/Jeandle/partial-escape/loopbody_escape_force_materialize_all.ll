; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:     -jeandle-pea-force-materialize-all %s | FileCheck %s

; Loop-body partial escape under forced MATERIALIZE_ALL escalation: the same
; Case A shape (alloc before loop, escape via @sink that flows to the latch),
; but with the MATERIALIZE_ALL testing knob forcing the escalation path. The
; result must still be sound: exactly one allocation, escape + post-loop use
; both resolve to it. Guards against the escalation path interacting badly
; with loop-body escape (e.g. double materialize or non-convergence).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare void @ret_use(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_loopbody_escape_materialize_all(i32 %n, i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
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

; CHECK-LABEL: define void @test_loopbody_escape_materialize_all
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(
; CHECK-NOT: jeandle.new_instance
; CHECK: call void @sink(ptr addrspace(1)
; CHECK: call void @ret_use(ptr addrspace(1)

!java-method-compilation = !{}
