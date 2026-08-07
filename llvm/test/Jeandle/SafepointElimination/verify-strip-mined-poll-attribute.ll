; RUN: opt -passes='verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=warn -disable-output < %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=WARN
; RUN: not --crash opt -passes='verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -disable-output < %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=ABORT

; A strip-mined nest is identified by the "jeandle.strip-mined-poll" call-site
; attribute on the poll that SafepointStripMining relocated onto the outer
; back-edge. The marker IS the relocated poll, so it cannot outlive the
; coverage it certifies. SafepointPollElimination<after-strip-mining> and this
; verifier are adjacent to strip mining in the pipeline and trust the
; attribute; without it, a poll-free inner loop is reported uncovered.

declare hotspotcc void @jeandle.safepoint_poll()
declare void @some.helper()
declare i64 @llvm.sadd.sat.i64(i64, i64)

; The pass-produced shape: inner loop poll-free with a SCEV-opaque clamped
; limit, outer latch carries the relocated poll with the attribute. Accepted
; without any structural re-derivation.
define void @accepts_attributed_nest(i64 %n) "java-method" {
entry:
  br label %outer.ph

outer.ph:
  br label %outer.header

outer.header:
  %outer.iv = phi i64 [ 0, %outer.ph ], [ %outer.iv.next, %outer.latch ]
  %outer.cond = icmp slt i64 %outer.iv, %n
  br i1 %outer.cond, label %inner.entry, label %exit

inner.entry:
  %batch.end = call i64 @llvm.sadd.sat.i64(i64 %outer.iv, i64 1000)
  %cap.cond = icmp slt i64 %batch.end, %n
  %inner.limit = select i1 %cap.cond, i64 %batch.end, i64 %n
  br label %inner.header

inner.header:
  %iv = phi i64 [ %outer.iv, %inner.entry ], [ %iv.next, %inner.latch ]
  br label %inner.latch

inner.latch:
  %iv.next = add nsw i64 %iv, 1
  %inner.cond = icmp slt i64 %iv.next, %inner.limit
  br i1 %inner.cond, label %inner.header, label %outer.latch

outer.latch:
  %outer.iv.next = phi i64 [ %iv.next, %inner.latch ]
  call hotspotcc void @jeandle.safepoint_poll() #0 [ "deopt"(i64 %outer.iv.next) ]
  br label %outer.header

exit:
  ret void
}

; Same nest, but the outer latch poll lacks the attribute: nothing marks the
; inner loop as strip-mined, and its clamped trip count is opaque to SCEV, so
; it is reported uncovered.
define void @rejects_unattributed_nest(i64 %n) "java-method" {
entry:
  br label %outer.ph

outer.ph:
  br label %outer.header

outer.header:
  %outer.iv = phi i64 [ 0, %outer.ph ], [ %outer.iv.next, %outer.latch ]
  %outer.cond = icmp slt i64 %outer.iv, %n
  br i1 %outer.cond, label %inner.entry, label %exit

inner.entry:
  %batch.end = call i64 @llvm.sadd.sat.i64(i64 %outer.iv, i64 1000)
  %cap.cond = icmp slt i64 %batch.end, %n
  %inner.limit = select i1 %cap.cond, i64 %batch.end, i64 %n
  br label %inner.header

inner.header:
  %iv = phi i64 [ %outer.iv, %inner.entry ], [ %iv.next, %inner.latch ]
  br label %inner.latch

inner.latch:
  %iv.next = add nsw i64 %iv, 1
  %inner.cond = icmp slt i64 %iv.next, %inner.limit
  br i1 %inner.cond, label %inner.header, label %outer.latch

outer.latch:
  %outer.iv.next = phi i64 [ %iv.next, %inner.latch ]
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %outer.iv.next) ]
  br label %outer.header

exit:
  ret void
}

; The attribute only counts on a poll in the parent loop's latch. Here it sits
; on a poll in the outer header instead, so the inner loop is not marked.
define void @rejects_attribute_on_outer_header(i64 %n) "java-method" {
entry:
  br label %outer.ph

outer.ph:
  br label %outer.header

outer.header:
  %outer.iv = phi i64 [ 0, %outer.ph ], [ %outer.iv.next, %outer.latch ]
  %outer.cond = icmp slt i64 %outer.iv, %n
  call hotspotcc void @jeandle.safepoint_poll() #0 [ "deopt"(i64 %outer.iv) ]
  br i1 %outer.cond, label %inner.entry, label %exit

inner.entry:
  %batch.end = call i64 @llvm.sadd.sat.i64(i64 %outer.iv, i64 1000)
  %cap.cond = icmp slt i64 %batch.end, %n
  %inner.limit = select i1 %cap.cond, i64 %batch.end, i64 %n
  br label %inner.header

inner.header:
  %iv = phi i64 [ %outer.iv, %inner.entry ], [ %iv.next, %inner.latch ]
  br label %inner.latch

inner.latch:
  %iv.next = add nsw i64 %iv, 1
  %inner.cond = icmp slt i64 %iv.next, %inner.limit
  br i1 %inner.cond, label %inner.header, label %outer.latch

outer.latch:
  %outer.iv.next = phi i64 [ %iv.next, %inner.latch ]
  br label %outer.header

exit:
  ret void
}

; The attribute on a non-poll call does not mark the nest either.
define void @rejects_attribute_on_non_poll(i64 %n) "java-method" {
entry:
  br label %outer.ph

outer.ph:
  br label %outer.header

outer.header:
  %outer.iv = phi i64 [ 0, %outer.ph ], [ %outer.iv.next, %outer.latch ]
  %outer.cond = icmp slt i64 %outer.iv, %n
  br i1 %outer.cond, label %inner.entry, label %exit

inner.entry:
  %batch.end = call i64 @llvm.sadd.sat.i64(i64 %outer.iv, i64 1000)
  %cap.cond = icmp slt i64 %batch.end, %n
  %inner.limit = select i1 %cap.cond, i64 %batch.end, i64 %n
  br label %inner.header

inner.header:
  %iv = phi i64 [ %outer.iv, %inner.entry ], [ %iv.next, %inner.latch ]
  br label %inner.latch

inner.latch:
  %iv.next = add nsw i64 %iv, 1
  %inner.cond = icmp slt i64 %iv.next, %inner.limit
  br i1 %inner.cond, label %inner.header, label %outer.latch

outer.latch:
  %outer.iv.next = phi i64 [ %iv.next, %inner.latch ]
  call void @some.helper() #0
  br label %outer.header

exit:
  ret void
}

attributes #0 = { "jeandle.strip-mined-poll" }

; WARN-NOT:  accepts_attributed_nest
; WARN:      'inner.header' in function 'rejects_unattributed_nest'
; WARN-NEXT: SafepointCoverageVerifier: loop with header 'inner.header' in function 'rejects_attribute_on_outer_header'
; WARN-NEXT: SafepointCoverageVerifier: loop with header 'outer.header' in function 'rejects_attribute_on_non_poll'
; WARN-NEXT: SafepointCoverageVerifier: loop with header 'inner.header' in function 'rejects_attribute_on_non_poll'

; ABORT-NOT: accepts_attributed_nest
; ABORT:     Jeandle safepoint coverage verification failed
