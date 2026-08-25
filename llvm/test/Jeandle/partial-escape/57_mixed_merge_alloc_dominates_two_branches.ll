; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Alloc-dominates fast path with escapes on BOTH arms via DIFFERENT
; sink calls. The mergeStates "AllMaterialized" branch fires (every incoming
; has the object Materialized). Under the reuse-OrigAlloc model every
; incoming's MaterializedValue resolves to the same ORIGINAL allocation
; (OrigAlloc), which dominates both arms and the merge, so no additional
; allocation invoke is emitted and no ptr addrspace(1) PHI is needed at
; the merge: both sinks and the return consume OrigAlloc.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink1(ptr addrspace(1))
declare void @sink2(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @test_both_arms_escape(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  br i1 %c, label %left, label %right
left:
  call void @sink1(ptr addrspace(1) %o)
  br label %merge
right:
  call void @sink2(ptr addrspace(1) %o)
  br label %merge
merge:
  ret ptr addrspace(1) %o
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @test_both_arms_escape
; Exactly one allocation invoke (the original, retained); each arm's sink and
; the return consume OrigAlloc; no materialized-object PHI at the merge.
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK-NOT: invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK: call void @sink1(ptr addrspace(1) %o)
; CHECK: call void @sink2(ptr addrspace(1) %o)
; CHECK-NOT: = phi ptr addrspace(1)
; CHECK: ret ptr addrspace(1) %o

!java-method-compilation = !{}
