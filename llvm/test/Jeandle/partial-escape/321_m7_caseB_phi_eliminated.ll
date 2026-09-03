; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A Case-B PHI (both incomings agree on the same ObjectID) for a
; NeverEscapes VO is explicitly erased after EliminateAllocation, so the
; IR doesn't carry a `phi ptr addrspace(1) [poison, poison]` survivor.
; Otherwise the PHI would survive (with poison incomings) until a
; downstream InstCombine reaped it — invisible in iterative mode but
; observable in single-shot PEA lit runs.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_caseB_phi_eliminated(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %branch unwind label %u
branch:
  br i1 %c, label %left, label %right
left:
  br label %merge
right:
  br label %merge
merge:
  %phi = phi ptr addrspace(1) [ %o, %left ], [ %o, %right ]
  ; The PHI is Case-B aliased to %o's VO; no real downstream user touches
  ; it as a pointer, so the VO ends up NeverEscapes and the PHI itself
  ; is dead-but-aliased after EliminateAllocation, which erases it.
  call void @use(i32 1)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Alloc + PHI both eliminated.
; CHECK-LABEL: define void @test_caseB_phi_eliminated
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: phi ptr addrspace(1)
; CHECK: call void @use(i32 1)

!java-method-compilation = !{}
