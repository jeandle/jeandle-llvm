; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA: an allocation made by invoke escapes via an opaque sink call in the
; normal-dest block. Materialization retains the original new_instance
; invoke (keeping its unwind edge) and the sink receives it directly; no
; new allocation is emitted at the escape point.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_mat_invoke() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  call void @sink(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_mat_invoke
; CHECK: %[[MAT:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
; CHECK-NEXT: to label %{{.*}} unwind label %{{.*}}
; CHECK: call void @sink(ptr addrspace(1) %[[MAT]])

!java-method-compilation = !{}
