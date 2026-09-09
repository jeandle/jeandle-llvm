; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; llvm.launder.invariant.group / llvm.strip.invariant.group are
; pointer-identity-preserving — PEA routes them through propagatePointer-
; Alias so the result pointer carries the same VirtualAlias as the
; argument. A load through the laundered pointer must therefore resolve
; against the original virtual's slot state.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare ptr addrspace(1) @llvm.launder.invariant.group.p1(ptr addrspace(1))
declare ptr addrspace(1) @llvm.strip.invariant.group.p1(ptr addrspace(1))
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_launder() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  ; Store through the original; load through a launder-then-strip alias.
  %s0 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 99, ptr addrspace(1) %s0 unordered, align 4
  %lo = call ptr addrspace(1) @llvm.launder.invariant.group.p1(ptr addrspace(1) %o)
  %so = call ptr addrspace(1) @llvm.strip.invariant.group.p1(ptr addrspace(1) %lo)
  %s1 = getelementptr inbounds i8, ptr addrspace(1) %so, i64 8
  %v = load atomic i32, ptr addrspace(1) %s1 unordered, align 4
  call void @use(i32 %v)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_launder
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: call void @use(i32 99)

!java-method-compilation = !{}
