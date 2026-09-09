; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Symbolic-offset derived GEP in an equality icmp. %g = gep %o, %sym where %sym
; is a non-constant SSA value, so resolveFieldOffset returns nullopt. The icmp
; can't be folded (the offset can't be proven equal or distinct to 0), so the
; object materializes AT the icmp: under
; reuse-OrigAlloc the materialized value IS OrigAlloc, which dominates %g and
; is kept alive (PartiallyEscapes), so the derived GEP stays valid. The icmp
; survives as a real compare over two valid pointers.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i1)
declare i32 @__gxx_personality_v0(...)

define void @test_icmp_eq_symbolic_offset(i64 %sym) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
         to label %n unwind label %u
n:
  %g = getelementptr inbounds i8, ptr addrspace(1) %o, i64 %sym
  %c = icmp eq ptr addrspace(1) %o, %g
  call void @use(i1 %c)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_icmp_eq_symbolic_offset
; The derived GEP must keep a real base (never poison).
; CHECK-NOT: getelementptr{{.*}}poison
; %o stays real and the icmp survives as a real compare (not folded).
; CHECK: invoke{{.*}}@jeandle.new_instance
; CHECK: icmp eq ptr addrspace(1)
; CHECK-NOT: call{{.*}}@use(i1 true)
; CHECK-NOT: call{{.*}}@use(i1 false)

!java-method-compilation = !{}
