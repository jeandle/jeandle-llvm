; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA A3 (Mixed-merge alloc-dominates fast path) with field stores in the
; if-then arm. The alloc is in %entry; the if-then arm writes a field then
; escapes; the if-else arm leaves the object virtual. Under the reuse-OrigAlloc
; model the ORIGINAL allocation is kept alive and dominates every use, so the
; tracked field write is replayed onto OrigAlloc before the escape and no
; materialized-object PHI is needed at the merge; the return consumes OrigAlloc.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @test_mixed_merge_with_field_writes(i1 %c, i32 %v)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  br i1 %c, label %then, label %else
then:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %v, ptr addrspace(1) %slot unordered, align 4
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

; Single allocation invoke retained (alloc dominates merge). The canonical
; field write at offset 8 is present on OrigAlloc before the escape; the sink
; and the return consume OrigAlloc; no materialized-object PHI is built.
; CHECK-LABEL: define ptr addrspace(1) @test_mixed_merge_with_field_writes
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK-NOT: invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK: %[[SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
; CHECK: store atomic i32 %v, ptr addrspace(1) %[[SLOT]] unordered, align 4
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK-NOT: = phi ptr addrspace(1)
; CHECK: ret ptr addrspace(1) %o

!java-method-compilation = !{}
