; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Edge case: two unrelated virtuals A and B passed as separate
; arguments to the same external sink call. Both escape at the same
; instruction. Both materialize at the call without interfering with each
; other (e.g. SeqNo collision, mis-ordering).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink2(ptr addrspace(1), ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_two_escapes_same_call() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
       to label %nA unwind label %u1
nA:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
       to label %nB unwind label %u2
nB:
  call void @sink2(ptr addrspace(1) %a, ptr addrspace(1) %b)
  ret void
u1:
  %lp1 = landingpad i64 cleanup
  resume i64 %lp1
u2:
  %lp2 = landingpad i64 cleanup
  resume i64 %lp2
}

; Both original allocations are retained, distinct klasses, and the sink
; call uses them directly.
; CHECK-LABEL: define void @test_two_escapes_same_call
; CHECK-DAG: invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
; CHECK-DAG: invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
; CHECK: call void @sink2(ptr addrspace(1) %{{.*}}, ptr addrspace(1) %{{.*}})

!java-method-compilation = !{}
