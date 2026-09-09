; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA: diamond CFG, both arms store different ptr addrspace(1) values into
; the same virtual's reference field (one null, one a function-arg pointer).
; mergeStates synthesizes a ptr addrspace(1) PHI at the merge block; the
; post-merge load forwards through it. The allocation is eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @test_field_phi_ref(i1 %c, ptr addrspace(1) %p)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  br i1 %c, label %left, label %right
left:
  %sl = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic ptr addrspace(1) null, ptr addrspace(1) %sl unordered, align 8
  br label %merge
right:
  %sr = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic ptr addrspace(1) %p, ptr addrspace(1) %sr unordered, align 8
  br label %merge
merge:
  %sm = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %v  = load atomic ptr addrspace(1), ptr addrspace(1) %sm unordered, align 8
  ret ptr addrspace(1) %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @test_field_phi_ref
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: phi ptr addrspace(1)
; CHECK-DAG: null
; CHECK-DAG: %p
; CHECK: ret ptr addrspace(1)

!java-method-compilation = !{}
