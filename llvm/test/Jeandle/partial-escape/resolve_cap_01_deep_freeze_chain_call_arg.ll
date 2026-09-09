; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; TODO(resolve-cap-blind-spot): a value that is virtual-derived but which
; resolveVirtualRef cannot resolve STRUCTURALLY (here: a >8-deep freeze chain,
; exceeding the ResolveVirtualRefMaxDepth cap of 8) used at an escape point must
; still materialize its underlying VO. Before the fix the call arg is skipped by
; resolveVirtualRef, the VO is classified NeverEscapes, its OrigAlloc is RAUW'd
; to poison, and the call receives a poison argument (miscompile). After the fix
; the VO is materialized (OrigAlloc kept) and the call receives a live pointer.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_resolve_cap_deep_freeze_chain_call_arg() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
          ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %cont unwind label %u
cont:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 42, ptr addrspace(1) %s unordered, align 4
  ; 10-deep freeze chain from %o — exceeds the resolveVirtualRef depth cap (8),
  ; so resolveVirtualRef(%f10) returns nullopt even though %f10 denotes %o.
  %f1  = freeze ptr addrspace(1) %o
  %f2  = freeze ptr addrspace(1) %f1
  %f3  = freeze ptr addrspace(1) %f2
  %f4  = freeze ptr addrspace(1) %f3
  %f5  = freeze ptr addrspace(1) %f4
  %f6  = freeze ptr addrspace(1) %f5
  %f7  = freeze ptr addrspace(1) %f6
  %f8  = freeze ptr addrspace(1) %f7
  %f9  = freeze ptr addrspace(1) %f8
  %f10 = freeze ptr addrspace(1) %f9
  ; Escape via call arg. The call must receive a live pointer derived from the
  ; kept OrigAlloc, never poison.
  call void @sink(ptr addrspace(1) %f10)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_resolve_cap_deep_freeze_chain_call_arg
; The allocation MUST survive (materialized, not eliminated to poison):
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: ret void
; CHECK: call void @sink(ptr addrspace(1) %{{.*}})
; CHECK-NOT: poison

!java-method-compilation = !{}
