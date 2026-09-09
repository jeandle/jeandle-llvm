; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Loop without a unique preheader: the header has two forward
; predecessors (%fwd_a, %fwd_b) and one back-edge predecessor (%latch).
; LoopInfo classifies this as a natural loop (single header, single
; back-edge); getLoopPreheader() returns nullptr because there is no
; single forward pred. The alloc-before-region (%o, created in %entry)
; is virtual at every forward pred's exit. processLoop's no-preheader
; branch marks every such VO INELIGIBLE, so the original alloc + stores +
; body @sink survive unmodified.
;
; This test deliberately runs PEA directly (no `loop-simplify` in the
; pipeline) so we exercise the in-analyzer fallback. In the full
; Jeandle pipeline LoopSimplifyPass would canonicalise this shape and
; the loop fixpoint would run instead.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_c6_no_preheader_virtual(i1 %p, i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %dispatch unwind label %u
dispatch:
  br i1 %p, label %fwd_a, label %fwd_b
fwd_a:
  br label %hdr
fwd_b:
  br label %hdr
hdr:
  %i = phi i32 [ 0, %fwd_a ], [ 0, %fwd_b ], [ %i1, %latch ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  call void @sink(ptr addrspace(1) %o)
  br label %latch
latch:
  %i1 = add i32 %i, 1
  br label %hdr
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The alloc survives in IR (irreducible-region bailout). Exactly one
; new_instance invoke; exactly one @sink call (no duplicate
; materializations).
; CHECK-LABEL: define void @test_c6_no_preheader_virtual
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: pea.mat

!java-method-compilation = !{}
