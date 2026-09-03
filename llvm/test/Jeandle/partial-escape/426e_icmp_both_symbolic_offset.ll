; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Equality icmp of two symbolic-offset derived GEPs of the SAME virtual object.
; %g1 = gep %o, %s1; %g2 = gep %o, %s2. Both offsets are non-constant, so
; resolveFieldOffset returns nullopt and the icmp can't be folded (the
; addresses can't be proven equal or distinct). The object materializes AT the
; icmp: under reuse-OrigAlloc the materialized value
; IS OrigAlloc, which dominates both GEPs and is kept alive (PartiallyEscapes),
; so both derived operands stay valid. The icmp survives as a real compare over
; two valid pointers.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i1)
declare i32 @__gxx_personality_v0(...)

define void @test_icmp_both_symbolic_offset(i64 %s1, i64 %s2) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
         to label %n unwind label %u
n:
  %g1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 %s1
  %g2 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 %s2
  %c = icmp eq ptr addrspace(1) %g1, %g2
  call void @use(i1 %c)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_icmp_both_symbolic_offset
; CHECK-NOT: getelementptr{{.*}}poison
; CHECK: invoke{{.*}}@jeandle.new_instance
; CHECK: icmp eq ptr addrspace(1)
; CHECK-NOT: call{{.*}}@use(i1 true)
; CHECK-NOT: call{{.*}}@use(i1 false)

!java-method-compilation = !{}
