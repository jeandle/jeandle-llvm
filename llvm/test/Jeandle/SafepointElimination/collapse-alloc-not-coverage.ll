; RUN: opt -passes='safepoint-poll-elimination<early>' -S < %s | FileCheck %s

; Within a straight-line (non-loop) block, a later alloc
; fast path must NOT let the block-local peephole delete an earlier poll: the
; alloc (a TLAB bump, no safepoint) does not catch a safepoint request, so the
; earlier poll is not redundant by adjacency. C2's SafePointNode::Identity
; Pattern B only treats a `guaranteed_safepoint()` call that way
; (callnode.cpp:1330); an AllocateNode (guaranteed_safepoint()==false) does
; not. isSafepoint() includes only polls and guaranteed-safepoint calls.

declare hotspotcc void @jeandle.safepoint_poll()
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32) #0

attributes #0 = { "jeandle.not-guaranteed-safepoint" }

define void @collapse_alloc_not_coverage() "java-method" {
entry:
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"() ]
  %o = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr null, i32 16) [ "deopt"() ]
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: define void @collapse_alloc_not_coverage(
; CHECK:      call hotspotcc void @jeandle.safepoint_poll()

; The marker may be attached directly to a call site. Classification must
; inspect both the call-site attributes and the resolved callee attributes.
declare hotspotcc void @callsite_marked_leaf()

define void @collapse_callsite_attr_not_coverage() "java-method" {
entry:
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"() ]
  call hotspotcc void @callsite_marked_leaf() #0 [ "deopt"() ]
  ret void
}

; CHECK-LABEL: define void @collapse_callsite_attr_not_coverage(
; CHECK:      call hotspotcc void @jeandle.safepoint_poll()
