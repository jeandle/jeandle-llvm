; RUN: opt -passes=safepoint-poll-elimination -S < %s | FileCheck %s

; A poll immediately before a deopt-bundle call in the same block is redundant:
; the call is itself a safepoint, and straight-line control guarantees it runs
; right after the poll, catching any safepoint request the poll would have. The
; poll is removed; the call is kept (deopt calls are never deleted). This is the
; block-level analog of C2's SafePointNode::Identity pattern B (poll after a
; guaranteed-safepoint call).

declare hotspotcc void @jeandle.safepoint_poll()
declare hotspotcc void @java_method()

define void @poll_before_call() "java-method" gc "safepoint-in-loop-example" {
entry:
  call hotspotcc void @jeandle.safepoint_poll()
  call hotspotcc void @java_method() [ "deopt"() ]
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @poll_before_call(
; CHECK-NOT: call hotspotcc void @jeandle.safepoint_poll
; CHECK:     call hotspotcc void @java_method() [ "deopt"() ]
; CHECK-NEXT: ret void
