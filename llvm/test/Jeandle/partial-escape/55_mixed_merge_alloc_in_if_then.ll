; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA A3 (Mixed-merge non-dominating alloc): the alloc-dominates-merge
; fast path. Alloc happens in %entry (which dominates the merge); the if-then
; arm escapes the object via @sink, the if-else arm leaves it virtual.
; Under the reuse-OrigAlloc model the ORIGINAL allocation is the single SSA
; value kept alive (it dominates every escape point and every use), so no
; additional allocation invoke is emitted and no materialized-object PHI is
; needed at the merge: the escape arm and the return both consume OrigAlloc.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @test_alloc_in_entry_mixed_merge(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  br i1 %c, label %then, label %else
then:
  call void @sink(ptr addrspace(1) %o)
  br label %merge
else:
  br label %merge
merge:
  ret ptr addrspace(1) %o
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The transform retains the single original allocation invoke (the alloc
; dominates the merge, so OrigAlloc is the one sound SSA value), and both the
; @sink and the return consume it; no materialized-object PHI is built.
; CHECK-LABEL: define ptr addrspace(1) @test_alloc_in_entry_mixed_merge
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK-NOT: invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK-NOT: = phi ptr addrspace(1)
; CHECK: ret ptr addrspace(1) %o

!java-method-compilation = !{}
