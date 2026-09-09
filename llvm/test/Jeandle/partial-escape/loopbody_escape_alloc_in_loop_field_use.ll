; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Loop-body partial escape, Case B with a loop-LOCAL allocation: the object is
; allocated INSIDE the loop, used virtually on the normal path (field store +
; load folding to the loop-variant %i), and escapes only on the `ret` branch
; that EXITS the loop. Jeandle retains the original loop-body allocation so
; its deopt bundle stays attached to the correct BCI. The partial-escape gain
; is that field state is replayed only on the escaping return; on continuing
; iterations the load still folds to %i.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @test_loopbody_local_escape(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %i1, %cont ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %st unwind label %u
st:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %i, ptr addrspace(1) %s unordered, align 4
  %ce = icmp eq i32 %i, 7
  br i1 %ce, label %ret, label %cont
ret:
  ret ptr addrspace(1) %o
cont:
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  call void @use(i32 %v)
  %i1 = add i32 %i, 1
  br label %loop
exit:
  ret ptr addrspace(1) null
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @test_loopbody_local_escape
; The original allocation is retained and its field state is replayed for the
; escaping return.
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(
; CHECK: store atomic i32 %i, ptr addrspace(1) %{{.*}} unordered, align 4
; CHECK: ret ptr addrspace(1) %{{.*}}
; The normal path stays virtual: the field load folds to %i.
; CHECK: call void @use(i32 %i)
; Exactly one allocation.
; CHECK-NOT: jeandle.new_instance

!java-method-compilation = !{}
