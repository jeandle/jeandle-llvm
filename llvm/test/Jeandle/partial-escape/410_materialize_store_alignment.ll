; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; The replayed field stores at a materialization point MUST carry the
; field type's natural ABI alignment, derived from the DataLayout — NOT a
; hardcoded `pointer ? 8 : 1`. The stores are atomic-unordered, and an atomic
; access that is not naturally aligned is illegal (lowers to a libcall / is
; rejected by the backend), so an under-aligned i32/float/i16 replay is a real
; miscompile. This test pins the alignment of every primitive width plus a
; reference field on materialization (escape via return).
;
; Offsets (instance, 64 bytes): i8@8, i16@10, i32@12, i64@16, float@24,
; double@32, ptr@40.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @test_store_alignment(ptr addrspace(1) %ref) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 9001 to ptr), i32 64, i1 false)
       to label %n unwind label %u
n:
  %p8 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i8 1, ptr addrspace(1) %p8 unordered, align 1
  %p16 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 10
  store atomic i16 2, ptr addrspace(1) %p16 unordered, align 2
  %p32 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  store atomic i32 3, ptr addrspace(1) %p32 unordered, align 4
  %p64 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i64 4, ptr addrspace(1) %p64 unordered, align 8
  %pf = getelementptr inbounds i8, ptr addrspace(1) %o, i64 24
  store atomic float 5.0, ptr addrspace(1) %pf unordered, align 4
  %pd = getelementptr inbounds i8, ptr addrspace(1) %o, i64 32
  store atomic double 6.0, ptr addrspace(1) %pd unordered, align 8
  %pp = getelementptr inbounds i8, ptr addrspace(1) %o, i64 40
  store atomic ptr addrspace(1) %ref, ptr addrspace(1) %pp unordered, align 8
  ret ptr addrspace(1) %o
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @test_store_alignment
; CHECK: %[[MAT:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 9001 to ptr), i32 64, i1 false)
; CHECK-DAG: store atomic i8 1, ptr addrspace(1) %{{.*}} unordered, align 1
; CHECK-DAG: store atomic i16 2, ptr addrspace(1) %{{.*}} unordered, align 2
; CHECK-DAG: store atomic i32 3, ptr addrspace(1) %{{.*}} unordered, align 4
; CHECK-DAG: store atomic i64 4, ptr addrspace(1) %{{.*}} unordered, align 8
; CHECK-DAG: store atomic float 5.000000e+00, ptr addrspace(1) %{{.*}} unordered, align 4
; CHECK-DAG: store atomic double 6.000000e+00, ptr addrspace(1) %{{.*}} unordered, align 8
; CHECK-DAG: store atomic ptr addrspace(1) %ref, ptr addrspace(1) %{{.*}} unordered, align 8
; CHECK: ret ptr addrspace(1) %[[MAT]]

!java-method-compilation = !{}
