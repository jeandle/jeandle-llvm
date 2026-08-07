; RUN: opt -passes=safepoint-poll-elimination -S < %s | FileCheck %s

; Polls live only in the two branch arms; neither dominates the latch.
; Deleting either could leave the other path's iterations uncovered, so
; keep-one must delete nothing (C2: no dominating safepoint found -> keep all).
; Non-counted loop (runtime-flag exits) so this exercises the keep-one prune
; gate rather than counted-loop deletion.

declare hotspotcc void @jeandle.safepoint_poll()

define void @no_dominating(i1 %c, i1 %keep_going) "java-method" gc "safepoint-in-loop-example" {
entry:
  br label %loop.header

loop.header:
  br i1 %c, label %then, label %else

then:
  call hotspotcc void @jeandle.safepoint_poll()
  br label %loop.latch

else:
  call hotspotcc void @jeandle.safepoint_poll()
  br label %loop.latch

loop.latch:
  br i1 %keep_going, label %loop.header, label %exit

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @no_dominating(
; CHECK:       then:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
; CHECK:       else:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
