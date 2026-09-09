; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; MergeProcessor / mergeObjectState AllMaterialized under the reuse-OrigAlloc
; model (escape-driven, NO materialized-object PHI).
;
; Both arms escape the same virtual object via a sink call. Under reuse-OrigAlloc
; the ORIGINAL allocation dominates both arms and the merge, so it is the single
; sound SSA value kept alive; no new allocation invoke is emitted and no
; materialized-object PHI is synthesized at the merge. Both sinks
; and the return consume OrigAlloc directly. Pinning the no-PHI outcome here
; guards the merge routing: escapes must NOT be misrouted into the
; PHI-synthesis else-branch.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @test_escape_driven_matphi(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %branch unwind label %u
branch:
  br i1 %c, label %left, label %right
left:
  call void @sink(ptr addrspace(1) %o)
  br label %merge
right:
  call void @sink(ptr addrspace(1) %o)
  br label %merge
merge:
  ret ptr addrspace(1) %o
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Both arms escape, but OrigAlloc dominates both arms and the merge, so it is
; the single SSA value: both sinks and the return consume OrigAlloc and no
; materialized-object PHI is built.
; CHECK-LABEL: define ptr addrspace(1) @test_escape_driven_matphi
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK-NOT: invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK-NOT: = phi ptr addrspace(1)
; CHECK: ret ptr addrspace(1) %o

!java-method-compilation = !{}
