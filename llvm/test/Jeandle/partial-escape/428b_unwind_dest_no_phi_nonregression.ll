; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; The retained allocation keeps its original PHI-less OOM cleanup edge. PEA
; must not synthesize a pea.unwind block merely because the object escapes.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_unwind_dest_no_phi() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
         to label %n unwind label %uw
n:
  call void @sink(ptr addrspace(1) %o)
  ret void
uw:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_unwind_dest_no_phi
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance
; The source allocation still unwinds directly to %uw; no synthesized block.
; CHECK-NOT: pea.unwind
; CHECK: call void @sink(ptr addrspace(1)

!java-method-compilation = !{}
