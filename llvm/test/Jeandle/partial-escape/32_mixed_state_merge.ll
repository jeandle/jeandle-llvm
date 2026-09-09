; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA mixed-state merge: branch %left escapes the object via a sink call,
; the other branch keeps it virtual until the merge. Because the original
; allocation (OrigAlloc) dominates every escape point and every use, it is
; the single sound SSA value kept alive; no additional allocation invoke is
; emitted and no materialized-object PHI is needed.
; The escape arm keeps OrigAlloc (PEA replays any tracked field stores onto it
; before the escape); the return consumes OrigAlloc directly.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @test_mixed_merge(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  br i1 %c, label %left, label %right
left:
  call void @sink(ptr addrspace(1) %o)
  br label %merge
right:
  br label %merge
merge:
  ret ptr addrspace(1) %o
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @test_mixed_merge
; Exactly one allocation invoke (the original, retained), and no materialized-
; object PHI at the merge.
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK-NOT: invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK: ret ptr addrspace(1) %o

!java-method-compilation = !{}
