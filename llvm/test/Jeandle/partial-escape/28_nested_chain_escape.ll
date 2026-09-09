; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Three-deep nested-virtual chain: A holds B (offset 8), B holds C (offset 8).
; Returning A escapes A; the analyzer must transitively materialize B (because
; A's field references B) and C (because B's field references C). All three
; source allocations are retained. Replay stores write OrigAlloc %c into %b
; and OrigAlloc %b into %a before %a is returned.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @test_nested_chain() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %c = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
       to label %nC unwind label %u1
nC:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
       to label %nB unwind label %u2
nB:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 33333 to ptr), i32 16, i1 false)
       to label %nA unwind label %u3
nA:
  %slotB = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic ptr addrspace(1) %c, ptr addrspace(1) %slotB unordered, align 8
  %slotA = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic ptr addrspace(1) %b, ptr addrspace(1) %slotA unordered, align 8
  ret ptr addrspace(1) %a
u1:
  %lp1 = landingpad i64 cleanup
  resume i64 %lp1
u2:
  %lp2 = landingpad i64 cleanup
  resume i64 %lp2
u3:
  %lp3 = landingpad i64 cleanup
  resume i64 %lp3
}

; CHECK-LABEL: define ptr addrspace(1) @test_nested_chain
; All three source allocation invokes remain; no additional allocation is
; synthesized by materialization.
; CHECK-DAG: invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
; CHECK-DAG: invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
; CHECK-DAG: invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 33333 to ptr), i32 16, i1 false)
; Two replay stores preserve the nested identities.
; CHECK: store atomic ptr addrspace(1) %c, ptr addrspace(1) %{{.*}} unordered
; CHECK: store atomic ptr addrspace(1) %b, ptr addrspace(1) %{{.*}} unordered
; CHECK: ret ptr addrspace(1) %a

!java-method-compilation = !{}
