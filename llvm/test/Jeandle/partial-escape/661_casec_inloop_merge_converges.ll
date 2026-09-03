; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Two distinct virtual objects merge at a NON-HEADER in-loop merge block.
; Case C synthesizes one merged VO for the PHI. The synthesized ObjectID
; must be stable across loop-fixpoint iterations (the CaseCVOCache covers
; every in-loop merge block, not just loop headers) — otherwise each
; iteration's exit states differ and the fixpoint escalates to
; MATERIALIZE_ALL, losing every virtualization in the loop.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink_i32(i32)
declare i32 @__gxx_personality_v0(...)

define void @casec_inloop_merge(i32 %n, i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %inc, %latch ]
  br i1 %c, label %t, label %e
t:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5551 to ptr), i32 32, i1 false)
       to label %m unwind label %u
e:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5551 to ptr), i32 32, i1 false)
       to label %m unwind label %u
m:
  %p = phi ptr addrspace(1) [ %a, %t ], [ %b, %e ]
  %f = getelementptr inbounds i8, ptr addrspace(1) %p, i64 16
  store i32 7, ptr addrspace(1) %f
  %v = load i32, ptr addrspace(1) %f
  call void @sink_i32(i32 %v)
  br label %latch
latch:
  %inc = add nuw i32 %i, 1
  %cmp = icmp ult i32 %inc, %n
  br i1 %cmp, label %loop, label %exit
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The fixpoint converges with both objects virtual: allocations eliminated,
; the field store/load folds to the stored constant.
; CHECK-LABEL: define void @casec_inloop_merge
; CHECK-NOT: call hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call void @sink_i32(i32 7)
; CHECK-NOT: store i32 7
; CHECK-NOT: %v = load i32

!java-method-compilation = !{}
