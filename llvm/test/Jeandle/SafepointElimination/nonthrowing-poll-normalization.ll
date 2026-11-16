; RUN: opt -passes='safepoint-poll-normalization' -verify-each -S %s | FileCheck %s
; RUN: opt -passes='safepoint-poll-normalization,simplifycfg' -verify-each -S %s | FileCheck %s --check-prefix=CLEAN
;
; Inlining into a caught Java call can turn nonthrowing polls into invokes.
; Restore their call form without losing the GC/deoptimization state, and
; retain the exception edge of an unrelated throwing operation.

declare hotspotcc void @jeandle.safepoint_poll()
declare void @may_throw()
declare i32 @personality(...)

define void @shared_handler(i32 %state) personality ptr @personality {
entry:
  invoke hotspotcc void @jeandle.safepoint_poll() #0 [ "deopt"(i32 %state) ]
      to label %throw.block unwind label %catch, !poll.marker !0
throw.block:
  invoke void @may_throw() to label %exit unwind label %catch
exit:
  ret void
catch:
  %origin = phi i32 [ 1, %entry ], [ 2, %throw.block ]
  %exception = landingpad { ptr, i32 } cleanup
  call void @observe(i32 %origin)
  resume { ptr, i32 } %exception
}
; CHECK-LABEL: define void @shared_handler(
; CHECK: entry:
; CHECK-NEXT: call hotspotcc void @jeandle.safepoint_poll() #[[POLL:[0-9]+]] [ "deopt"(i32 %state) ], !poll.marker !0
; CHECK-NEXT: br label %throw.block
; CHECK: invoke void @may_throw()
; CHECK: catch:
; CHECK-NOT: phi
; CHECK: call void @observe(i32 2)
; CLEAN-LABEL: define void @shared_handler(
; CLEAN: call hotspotcc void @jeandle.safepoint_poll()
; CLEAN-NEXT: invoke void @may_throw()

define void @poll_only() personality ptr @personality {
entry:
  invoke hotspotcc void @jeandle.safepoint_poll() [ "deopt"() ]
      to label %exit unwind label %catch
exit:
  ret void
catch:
  %exception = landingpad { ptr, i32 } cleanup
  resume { ptr, i32 } %exception
}
; CHECK-LABEL: define void @poll_only(
; CHECK: call hotspotcc void @jeandle.safepoint_poll() #[[ORDINARY:[0-9]+]] [ "deopt"() ]
; CHECK-NEXT: br label %exit
; CLEAN-LABEL: define void @poll_only(
; CLEAN: call hotspotcc void @jeandle.safepoint_poll()
; CLEAN-NEXT: ret void
; CLEAN-NEXT: }

define void @ordinary_poll() {
entry:
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"() ]
  ret void
}
; CHECK-LABEL: define void @ordinary_poll(
; CHECK: call hotspotcc void @jeandle.safepoint_poll() #[[ORDINARY]] [ "deopt"() ]
; CHECK: attributes #[[POLL]] = { nounwind "jeandle.strip-mined-poll" }
; CHECK: attributes #[[ORDINARY]] = { nounwind }

declare void @observe(i32)
attributes #0 = { "jeandle.strip-mined-poll" }
!0 = !{i32 7}
