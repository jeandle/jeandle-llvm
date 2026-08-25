; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; When processBlockPhis Case-A fallback materialises a virtual
; incoming at a pred, the per-VO loop must re-run so subsequent decisions
; see the updated pred ExitInfo. The unified do-while (per-VO loop +
; phi loop, both inside the same `do ... while (Changed)`) provides
; this. Below: a single virtual is allocated up-front; one branch keeps
; it virtual, the other escapes it through @sink. The merge has a
; ptr addrspace(1) PHI whose Case-A handling materialises on the virtual
; arm. The per-VO loop in iter 2 of the do-while sees BOTH preds as
; Materialised and synthesises a CreatePHI for the merge.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare void @consume(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_caseA_retriggers_per_vo(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %branch unwind label %u
branch:
  br i1 %c, label %escape, label %fast
escape:
  call void @sink(ptr addrspace(1) %o)
  br label %merge
fast:
  br label %merge
merge:
  ; The PHI's first incoming is %o (already materialised on the escape
  ; arm); the fast arm still has %o virtual.
  %phi = phi ptr addrspace(1) [ %o, %escape ], [ %o, %fast ]
  call void @consume(ptr addrspace(1) %phi)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The alloc must survive (escape arm uses it); IR remains well-formed
; (verifyFunction passes).
; CHECK-LABEL: define void @test_caseA_retriggers_per_vo
; CHECK: invoke{{.*}}@jeandle.new_instance
; CHECK: call void @sink
; CHECK: call void @consume

!java-method-compilation = !{}
