; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; An object allocated BEFORE the loop is captured (escapes) on a CONDITIONAL
; path INSIDE the body that then CONTINUES to the latch (so the escape block
; is a loop block -> EscapeLoop != AllocLoop). The object is not used after the loop.
; Jeandle retains the one source OrigAlloc before the loop and places any
; required replay at the preheader, so the capture uses that same value on
; every iteration.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @capture(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_no_loop_iteration(i32 %n, i32 %k) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %loop unwind label %u
loop:
  %i = phi i32 [ 0, %entry ], [ %i1, %cont ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  %ce = icmp eq i32 %i, %k
  br i1 %ce, label %esc, label %cont
esc:
  call void @capture(ptr addrspace(1) %o)
  br label %cont
cont:
  %i1 = add i32 %i, 1
  br label %loop
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_no_loop_iteration
; Exactly one allocation before the loop; the capture uses it.
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(
; CHECK: call void @capture(ptr addrspace(1)
; CHECK-NOT: jeandle.new_instance

!java-method-compilation = !{}
