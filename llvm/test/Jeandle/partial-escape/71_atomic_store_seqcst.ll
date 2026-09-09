; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Atomics: a virtual receives a `store atomic seq_cst` on its
; field, then escapes via @sink. The materialization must replay the field
; store (per applyMaterialize, replay stores are emitted as
; atomic-unordered, matching jeandle-jdk's emission convention). The original
; atomic seq_cst store is removed.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_atomic_seqcst() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 99, ptr addrspace(1) %s seq_cst, align 4
  call void @sink(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The seq_cst store is gone. The source allocation remains, followed by the
; replayed unordered store and the sink consuming OrigAlloc.
; CHECK-LABEL: define void @test_atomic_seqcst
; CHECK-NOT: store atomic i32 99,{{.*}}seq_cst
; CHECK: %[[ORIG:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
; CHECK-NEXT: to label %{{.*}} unwind label %{{.*}}
; CHECK-NOT: @jeandle.new_instance
; CHECK: store atomic i32 99,{{.*}}unordered
; CHECK: call void @sink(ptr addrspace(1) %[[ORIG]])

!java-method-compilation = !{}
