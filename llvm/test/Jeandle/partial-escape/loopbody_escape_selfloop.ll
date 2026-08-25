; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Loop-body partial escape in a true SELF-LOOP (a single block whose terminator
; branches back to itself). The object is allocated before the loop and escapes
; inside the self-loop body. Verifies the loop fixpoint handles a self back-edge
; and produces a single materialization.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_selfloop_escape(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %loop unwind label %u
loop:
  %i = phi i32 [ 0, %entry ], [ %i1, %loop ]
  call void @sink(ptr addrspace(1) %o)
  %i1 = add i32 %i, 1
  %c = icmp slt i32 %i, %n
  br i1 %c, label %loop, label %exit
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_selfloop_escape
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(
; CHECK-NOT: jeandle.new_instance
; CHECK: call void @sink(ptr addrspace(1)

!java-method-compilation = !{}
