; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; llvm.lifetime.start / llvm.lifetime.end on a virtual must be
; recognised as no-op intrinsics. The alloc still escapes nowhere visible and
; must be eliminable.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @llvm.lifetime.start.p1(i64, ptr addrspace(1))
declare void @llvm.lifetime.end.p1(i64, ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_lifetime_noop() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  call void @llvm.lifetime.start.p1(i64 16, ptr addrspace(1) %o)
  call void @llvm.lifetime.end.p1(i64 16, ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_lifetime_noop
; CHECK-NOT: jeandle.new_instance
; CHECK: ret void

!java-method-compilation = !{}
