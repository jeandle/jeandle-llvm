; RUN: not opt -S -passes='java-operation-lower<phase=1>' %s 2>&1 | FileCheck %s
;
; A barrier-named call that violates the recognition contract must fail
; loudly instead of being lowered (or ignored) with the wrong semantics.
; The valid marker before it proves the pass processes calls in order and
; reaches the malformed one, so the fatal is not a vacuous pass.
;
; CHECK: invalid Jeandle memory barrier call
declare hotspotcc void @jeandle.membar_release()
declare hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1))

define void @ordered(ptr addrspace(1) %p) {
  ; Valid: lowered normally when the malformed call below is removed.
  call hotspotcc void @jeandle.membar_release()
  ; Malformed: barrier calls must carry no operand bundles — a deopt bundle
  ; would let later passes treat this ordering marker as a real call site.
  call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %p) [ "deopt"() ]
  ret void
}
