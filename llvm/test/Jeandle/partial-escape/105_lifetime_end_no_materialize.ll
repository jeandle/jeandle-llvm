; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Edge case: virtual with llvm.lifetime.start / llvm.lifetime.end
; bracketing its store/load region. lifetime.end on a virtual must NOT
; trigger materialization. Allocation is fully eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @llvm.lifetime.start.p1(i64, ptr addrspace(1))
declare void @llvm.lifetime.end.p1(i64, ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i32 @test_lifetime_end_no_materialize() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  call void @llvm.lifetime.start.p1(i64 16, ptr addrspace(1) %o)
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 99, ptr addrspace(1) %s unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  call void @llvm.lifetime.end.p1(i64 16, ptr addrspace(1) %o)
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_lifetime_end_no_materialize
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: ret i32 99

!java-method-compilation = !{}
