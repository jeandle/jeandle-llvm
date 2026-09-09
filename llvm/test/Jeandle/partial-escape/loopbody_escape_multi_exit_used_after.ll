; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Loop-body partial escape with MULTIPLE loop exits that all use the object
; after the loop. The object is allocated before the loop, escapes in the body
; via @sink (case A), and is consumed on both the natural exit and a
; conditional side exit. A single materialization must dominate both exits.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare void @ret_use_a(ptr addrspace(1))
declare void @ret_use_b(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_multi_exit_used_after(i32 %n, i32 %k) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %prep unwind label %u
prep:
  br label %loop
loop:
  %i = phi i32 [ 0, %prep ], [ %i1, %cont ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit1
body:
  %c2 = icmp eq i32 %i, %k
  br i1 %c2, label %exit2, label %cont
cont:
  call void @sink(ptr addrspace(1) %o)
  %i1 = add i32 %i, 1
  br label %loop
exit1:
  call void @ret_use_a(ptr addrspace(1) %o)
  ret void
exit2:
  call void @ret_use_b(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_multi_exit_used_after
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(
; CHECK-NOT: jeandle.new_instance
; Both post-loop exits receive the single materialized pointer.
; CHECK: call void @ret_use_a(ptr addrspace(1)
; CHECK: call void @ret_use_b(ptr addrspace(1)

!java-method-compilation = !{}
