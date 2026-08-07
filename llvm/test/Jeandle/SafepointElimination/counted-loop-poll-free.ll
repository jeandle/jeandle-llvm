; RUN: opt -passes='safepoint-poll-elimination,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -jeandle-loop-strip-mining-iter=0 -S < %s | FileCheck %s

; C2 deletes every safepoint poll of an int counted loop when strip mining is
; off (counted_loop with LoopStripMiningIter == 0): the loop terminates within
; the IV's type range, so its time-to-safepoint is finite. The back-edge poll
; below is removed and the coverage verifier certifies the now-poll-free loop.
; Both an unbounded (runtime-limit) and a bounded (constant-limit) counted loop
; lose their polls.

declare hotspotcc void @jeandle.safepoint_poll()

define void @unbounded_counted(i32 %n) "java-method" {
entry:
  br label %loop.header

loop.header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop.header ]
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv) ]
  %iv.next = add nsw i32 %iv, 1
  %exit.cond = icmp slt i32 %iv.next, %n
  br i1 %exit.cond, label %loop.header, label %exit

exit:
  ret void
}

; Pre-test (while-form) loop with a runtime bound and no nuw/nsw on the IV
; increment, as the Java frontend emits it: the exit test compares the
; PRE-inc IV and the latch increments. SCEV's symbolic max backedge-taken
; count is smax(0, n) with constant max exactly INT_MAX, so it does not satisfy
; the strict < INT_MAX threshold and must retain its poll. The post-inc shape
; above has max BTC n-1 < INT_MAX and remains poll-free.
define void @pretest_counted(i32 %n) "java-method" {
entry:
  br label %loop.header

loop.header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop.latch ]
  %exit.cond = icmp slt i32 %iv, %n
  br i1 %exit.cond, label %loop.latch, label %exit

loop.latch:
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv) ]
  %iv.next = add i32 %iv, 1
  br label %loop.header

exit:
  ret void
}

define void @bounded_counted(ptr %a) "java-method" {
entry:
  br label %loop.header

loop.header:
  %iv = phi i32 [ 0, %entry ], [ %iv.next, %loop.header ]
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv) ]
  %p = getelementptr inbounds i32, ptr %a, i32 %iv
  store i32 0, ptr %p
  %iv.next = add nuw nsw i32 %iv, 1
  %exit.cond = icmp slt i32 %iv.next, 5000
  br i1 %exit.cond, label %loop.header, label %exit

exit:
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: @unbounded_counted(
; CHECK-NOT:   call hotspotcc void @jeandle.safepoint_poll
; CHECK-LABEL: @pretest_counted(
; CHECK:       call hotspotcc void @jeandle.safepoint_poll()
; CHECK-LABEL: @bounded_counted(
; CHECK-NOT:   call hotspotcc void @jeandle.safepoint_poll
