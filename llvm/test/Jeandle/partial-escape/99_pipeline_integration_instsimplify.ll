; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform,instsimplify" %s | FileCheck %s

; Pipeline integration sanity: running PEA followed by
; InstSimplify must produce well-formed IR — no broken SSA, no dangling PHIs,
; no malformed terminators. The presence of InstSimplify after PEA exercises
; the post-PEA verifier path implicitly (opt verifies the module before each
; pass). This test deliberately drives multiple PEA effects (tier-2 load fold,
; per-field PHI synthesis, alloc elimination) so that InstSimplify has enough
; surface to fail on if PEA emitted ill-formed IR.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @test_pipeline(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  br i1 %c, label %left, label %right
left:
  %sl = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 7, ptr addrspace(1) %sl unordered, align 4
  br label %merge
right:
  %sr = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 13, ptr addrspace(1) %sr unordered, align 4
  br label %merge
merge:
  %sm = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %v  = load atomic i32, ptr addrspace(1) %sm unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The IR is well-formed (opt would have aborted otherwise). The alloc, store,
; and load are all gone; a phi i32 of 7/13 feeds the return.
; CHECK-LABEL: define i32 @test_pipeline
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: = phi i32
; CHECK: ret i32

!java-method-compilation = !{}
