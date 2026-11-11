; RUN: opt -passes='loop-simplify,lcssa,safepoint-poll-elimination<early>,safepoint-poll-elimination<after-strip-mining>,verify<domtree>,verify<loops>,verify<jeandle-safepoint-coverage>,verify' \
; RUN:   -jeandle-loop-strip-mining-iter=0 -jeandle-verify-safepoint-coverage=fatal -verify-each -S < %s | FileCheck %s
; RUN: opt -passes='loop-simplify,lcssa,safepoint-poll-elimination<loop-deletion-prep>,verify' \
; RUN:   -verify-each -S < %s | FileCheck %s --check-prefix=EMPTY

; Generalizing poll recognition must not leave CallInst casts in the adjacent
; elimination passes. Only strip-mined inner invokes with a surviving outer
; exceptional predecessor are deleted. Ordinary invokes remain terminators.
declare hotspotcc void @jeandle.safepoint_poll()
declare hotspotcc void @guaranteed_safepoint()

define void @bounded_invoke(ptr %sink) "java-method" personality ptr null {
entry:
  br label %header
header:
  %i = phi i32 [ 0, %entry ], [ %next, %latch ]
  store i32 %i, ptr %sink
  %next = add nuw nsw i32 %i, 1
  invoke hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %next) ]
      to label %latch unwind label %unwind
latch:
  %more = icmp ult i32 %next, 128
  br i1 %more, label %header, label %exit
unwind:
  %exception = landingpad i64 cleanup
  ret void
exit:
  ret void
}
; CHECK-LABEL: define void @bounded_invoke(
; CHECK:       header:
; CHECK:       invoke hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    to label %latch unwind label %unwind
; CHECK:       }

define void @internal_handler(ptr %sink) "java-method" personality ptr null {
entry:
  br label %header
header:
  %i = phi i32 [ 0, %entry ], [ %next, %latch ]
  store i32 %i, ptr %sink
  %next = add nuw nsw i32 %i, 1
  invoke hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %next) ]
      to label %latch unwind label %handler
handler:
  %exception = landingpad i64 cleanup
  br label %latch
latch:
  %more = icmp ult i32 %next, 128
  br i1 %more, label %header, label %exit
exit:
  ret void
}
; CHECK-LABEL: define void @internal_handler(
; CHECK:       invoke hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    to label %latch unwind label %handler
; CHECK:       }

; A guaranteed safepoint in a non-loop block must not cause the terminator
; invoke to be erased as though it were a call.
define void @straight_line_invoke() "java-method" personality ptr null {
entry:
  call hotspotcc void @guaranteed_safepoint() [ "deopt"() ]
  invoke hotspotcc void @jeandle.safepoint_poll() [ "deopt"() ]
      to label %exit unwind label %unwind
unwind:
  %exception = landingpad i64 cleanup
  ret void
exit:
  ret void
}
; CHECK-LABEL: define void @straight_line_invoke(
; CHECK:       invoke hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    to label %exit unwind label %unwind

; Empty-loop deletion deliberately supports calls only. Keep its refusal
; behavior, rather than inheriting invoke support accidentally.
define void @empty_invoke_loop() "java-method" personality ptr null {
entry:
  br label %header
header:
  %i = phi i32 [ 0, %entry ], [ %next, %latch ]
  %next = add nuw nsw i32 %i, 1
  invoke hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %next) ]
      to label %latch unwind label %unwind
latch:
  %more = icmp ult i32 %next, 128
  br i1 %more, label %header, label %exit
unwind:
  %exception = landingpad i64 cleanup
  ret void
exit:
  ret void
}
; EMPTY-LABEL: define void @empty_invoke_loop(
; EMPTY:       invoke hotspotcc void @jeandle.safepoint_poll()
; EMPTY-NEXT:    to label %latch unwind label %unwind

; Deleting the inner invoke would make the ancestor's only latch unreachable.
; Keeping the invoke avoids querying the updated DT through stale LoopInfo.
define void @handler_is_ancestor_latch(ptr %sink) "java-method" personality ptr null {
entry:
  br label %outer.header
outer.header:
  br label %inner.preheader
inner.preheader:
  br label %inner.header
inner.header:
  %i = phi i32 [ 0, %inner.preheader ], [ %next, %inner.latch ]
  store i32 %i, ptr %sink
  %next = add nuw nsw i32 %i, 1
  invoke hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %next) ]
      to label %inner.latch unwind label %handler
inner.latch:
  %more = icmp ult i32 %next, 128
  br i1 %more, label %inner.header, label %exit
handler:
  %exception = landingpad i64 cleanup
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"() ]
  br label %outer.header
exit:
  ret void
}
; CHECK-LABEL: define void @handler_is_ancestor_latch(
; CHECK:       invoke hotspotcc void @jeandle.safepoint_poll()
; CHECK-NEXT:    to label %inner.latch unwind label %handler
; CHECK:       handler:
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       br label %outer.header

!java-method-compilation = !{}
