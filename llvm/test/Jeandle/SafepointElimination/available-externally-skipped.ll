; RUN: opt -passes=safepoint-poll-elimination -S < %s | FileCheck %s

; An available_externally "java-method" function is an inlined-callee reference,
; not the single compiled Java method body. isJeandleJavaMethodBody scopes the
; safepoint passes to that emitted body (a real definition that is neither a
; lower-phase helper nor available_externally), so @callee must be skipped and its
; adjacent polls survive. The earlier module-level-only predicate wrongly processed
; every non-lower-phase function in a java-method module, including this one.

declare hotspotcc void @jeandle.safepoint_poll()

define available_externally void @callee(i32 %n) "java-method" gc "method" {
entry:
  call hotspotcc void @jeandle.safepoint_poll()
  call hotspotcc void @jeandle.safepoint_poll()
  ret void
}

define void @root(ptr %p) "java-method" gc "method" {
entry:
  %v = load i32, ptr %p
  %c = icmp eq i32 %v, 0
  br i1 %c, label %exit, label %exit

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: define available_externally void @callee(
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:  call hotspotcc void @jeandle.safepoint_poll()
