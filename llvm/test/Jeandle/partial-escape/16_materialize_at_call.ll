; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA: alloc in entry, store one field in normal, then pass the oop
; to an opaque sink. The opaque call is an escape point. The original
; new_instance invoke is retained (it already dominates the sink), the
; field store stays before the escape, and the sink receives OrigAlloc.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_mat_call() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 42, ptr addrspace(1) %s unordered, align 4
  call void @sink(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_mat_call
; CHECK: %[[MAT:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
; CHECK-NEXT: to label %{{.*}} unwind label %{{.*}}
; CHECK: store atomic i32 42, ptr addrspace(1) %{{.*}} unordered, align {{[0-9]+}}
; CHECK: call void @sink(ptr addrspace(1) %[[MAT]])

!java-method-compilation = !{}
