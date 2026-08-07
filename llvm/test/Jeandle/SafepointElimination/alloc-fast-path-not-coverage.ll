; RUN: opt -passes='safepoint-poll-elimination<early>' -jeandle-loop-strip-mining-iter=0 -S < %s | FileCheck %s

; An allocation fast-path call (`jeandle.new_instance`) carries a "deopt"
; operand bundle for deoptimization STATE, not because it polls every
; invocation: its fast path is a TLAB bump with no poll and no VM call
; (template.ll:296-338); only the slow path `@new_instance` is a genuine VM
; safepoint. The callee is marked `"jeandle.not-guaranteed-safepoint"`,
; mirroring C2's `AllocateNode::guaranteed_safepoint()==false`
; (src/hotspot/share/opto/callnode.hpp). Such a call must NOT count as loop
; coverage. A non-counted loop (no integer induction phi; data-dependent exit)
; whose latch holds both the alloc fast path and the back-edge poll must KEEP
; its poll (C2 non-counted → `IdealLoopTree::remove_safepoints(keep_one=true)`,
; loopnode.cpp:4086). Without the not-guaranteed distinction the deopt bundle
; mislabels the alloc as call coverage and `deleteLoopPolls` deletes the keeper,
; leaving a possibly unbounded loop with no safepoint.

declare hotspotcc void @jeandle.safepoint_poll()
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32) #0

attributes #0 = { "jeandle.not-guaranteed-safepoint" }

define void @alloc_not_coverage(ptr %flag) "java-method" {
entry:
  br label %header

header:
  %done = load i1, ptr %flag, align 1
  br i1 %done, label %exit, label %latch

latch:
  %o = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr null, i32 16) [ "deopt"() ]
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"() ]
  br label %header

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: define void @alloc_not_coverage(
; CHECK:      call hotspotcc void @jeandle.safepoint_poll()
