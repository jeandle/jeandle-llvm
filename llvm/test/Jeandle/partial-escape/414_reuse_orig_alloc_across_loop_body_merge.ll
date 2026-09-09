; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -verify-each %s | FileCheck %s
;
; Reuse of one dominating OrigAlloc across a loop-body diamond.
;
; A loop-local object %X is allocated in the loop body and escapes on BOTH arms
; of an in-body diamond (@sink on each). Under the reuse-OrigAlloc model the
; ORIGINAL allocation %X dominates both arms and the post-merge use, so it is
; the single sound SSA def: each arm's sink AND the in-body @use all bind to
; OrigAlloc %X. No additional allocation or materialized-object PHI is
; synthesized: @use cannot be bound to a non-dominating value, and no poison
; is introduced. (The object is still carried across the back-edge by the
; header PHI %px, which is unrelated to replay placement.)

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare void @use(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_reuse_orig_alloc_across_loop_body_merge(i32 %n, i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %ohdr
ohdr:
  %oi = phi i32 [ 0, %entry ], [ %oi1, %olatch ]
  %px = phi ptr addrspace(1) [ null, %entry ], [ %X, %olatch ]
  %oc = icmp slt i32 %oi, %n
  br i1 %oc, label %obody, label %oexit
obody:
  %X = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5555 to ptr), i32 16, i1 false)
       to label %arm unwind label %u
arm:
  br i1 %c, label %a1, label %a2
a1:
  call void @sink(ptr addrspace(1) %X)
  br label %amrg
a2:
  call void @sink(ptr addrspace(1) %X)
  br label %amrg
amrg:
  call void @use(ptr addrspace(1) %X)
  br label %olatch
olatch:
  %oi1 = add i32 %oi, 1
  br label %ohdr
oexit:
  call void @sink(ptr addrspace(1) %px)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The single OrigAlloc %X dominates both arms and the post-merge @use; every
; sink and the in-body @use bind to %X — no PHI, no poison.
; CHECK-LABEL: define void @test_reuse_orig_alloc_across_loop_body_merge
; CHECK: %X = invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK-NOT: invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK: call void @sink(ptr addrspace(1) %X)
; CHECK: call void @sink(ptr addrspace(1) %X)
; CHECK-NOT: = phi ptr addrspace(1)
; CHECK: call void @use(ptr addrspace(1) %X)
; CHECK-NOT: poison

!java-method-compilation = !{}
