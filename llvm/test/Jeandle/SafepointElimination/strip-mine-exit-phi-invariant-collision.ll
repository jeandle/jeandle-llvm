; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>' -S < %s | FileCheck %s

; Loop canonicalization removes the unused %x recurrence. The unrelated equal
; constant leaking through the exit phi must remain 42 while the primary exit
; is rewired through the outer loop.

declare hotspotcc void @jeandle.safepoint_poll()

define i64 @invariant_exit_phi_collision(i64 %n) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %x = phi i64 [ 7, %entry ], [ 42, %latch ]
  %cond = icmp slt i64 %iv, %n
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next, i64 42) ]
  br label %latch

latch:
  br label %header

exit:
  %r = phi i64 [ 42, %header ]
  ret i64 %r
}

!java-method-compilation = !{}

; CHECK-LABEL: @invariant_exit_phi_collision(
; CHECK:       header.exit_crit_edge:
; CHECK:         %split = phi i64 [ 42, %body.outer ]
; CHECK:       exit:
; CHECK:         %r = phi i64 [ %split, %header.exit_crit_edge ], [ 42, %entry ]
; CHECK-NOT:   %x.outer
