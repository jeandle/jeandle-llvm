; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal \
; RUN:   -S < %s | FileCheck %s

; All four i64 loops are strip-mined. The first three have SCEV-proven backedge
; bounds below INT_MAX (masked limits / bounded decreasing forms); a bounded
; trip no longer opts a loop out of strip mining (it bounds TTSP tighter to the
; chunk size, matching C2's int counted loops). The final unsigned loop is
; likewise strip-mined.

declare hotspotcc void @jeandle.safepoint_poll()

define void @inc_step2_masked_limit(i64 noundef %raw) "java-method" {
entry:
  %n = and i64 %raw, 1000000
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp sle i64 %iv, %n
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add i64 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

; CHECK-LABEL: @inc_step2_masked_limit(
; CHECK:         .outer
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}}

define void @dec_step2_to_zero(i64 noundef %raw) "java-method" {
entry:
  %start = and i64 %raw, 1000000
  br label %header

header:
  %iv = phi i64 [ %start, %entry ], [ %iv.next, %latch ]
  %cond = icmp sge i64 %iv, 0
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add i64 %iv, -2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

; CHECK-LABEL: @dec_step2_to_zero(
; CHECK:         .outer
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}}

define void @uinc_step2_masked_limit(i64 noundef %raw) "java-method" {
entry:
  %n = and i64 %raw, 1000000
  br label %header

header:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %latch ]
  %cond = icmp ule i64 %iv, %n
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add i64 %iv, 2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

; CHECK-LABEL: @uinc_step2_masked_limit(
; CHECK:         .outer
; CHECK:         call hotspotcc void @jeandle.safepoint_poll() #{{[0-9]+}}

define void @udec_step2_to_two(i64 noundef %raw) "java-method" {
entry:
  br label %header

header:
  %iv = phi i64 [ %raw, %entry ], [ %iv.next, %latch ]
  %cond = icmp uge i64 %iv, 2
  br i1 %cond, label %body, label %exit

body:
  %iv.next = add i64 %iv, -2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
  br label %latch

latch:
  br label %header

exit:
  ret void
}

; CHECK-LABEL: @udec_step2_to_two(
; CHECK:         %outer.cond = icmp uge i64 %outer.iv, 2
; CHECK:         %outer.batch.end = call i64 @llvm.usub.sat.i64(i64 %outer.iv, i64 1998)
; CHECK:         icmp uge i64 %outer.batch.end, 2
; CHECK:         call hotspotcc void @jeandle.safepoint_poll()

!java-method-compilation = !{}

; CHECK:       attributes #{{[0-9]+}} = { "jeandle.strip-mined-poll" }
