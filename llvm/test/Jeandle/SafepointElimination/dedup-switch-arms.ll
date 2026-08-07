; RUN: opt -jeandle-loop-strip-mining-iter=0 -passes=safepoint-poll-elimination -S < %s | FileCheck %s

; Polls in switch arms are redundant when a poll in the latch dominates every
; complete iteration: keep-one erases the arm polls and tags the latch poll as
; the loop's designated coverage. Non-counted loop (switch + runtime-flag exit).

declare hotspotcc void @jeandle.safepoint_poll()

define void @switch_arms(i64 %rem, i1 %keep_going) "java-method" gc "safepoint-in-loop-example" {
entry:
  br label %loop.header

loop.header:
  switch i64 %rem, label %arm.default [
    i64 0, label %arm.a
    i64 1, label %arm.b
  ]

arm.a:
  call hotspotcc void @jeandle.safepoint_poll()
  br label %loop.latch

arm.b:
  call hotspotcc void @jeandle.safepoint_poll()
  br label %loop.latch

arm.default:
  br label %loop.latch

loop.latch:
  call hotspotcc void @jeandle.safepoint_poll()
  br i1 %keep_going, label %loop.header, label %exit

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @switch_arms(
; CHECK:       arm.a:
; CHECK-NEXT:    br label %loop.latch
; CHECK:       arm.b:
; CHECK-NEXT:    br label %loop.latch
; CHECK:       loop.latch:
; CHECK-NEXT:    call hotspotcc void @jeandle.safepoint_poll()
