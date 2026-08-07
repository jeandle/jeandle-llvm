; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,safepoint-strip-mining<strip-mining>' \
; RUN:   -S < %s | FileCheck %s

; Idempotency: the outer loop a strip-mine creates must not be
; re-wrapped by a later run. After the first run the inner loop is poll-free
; (nothing to relocate) and the new outer loop is non-innermost (ineligible),
; so a second strip-mining run is a no-op. The result must carry exactly one
; strip-mine wrap — a re-wrap would duplicate the coverage poll.

declare hotspotcc void @jeandle.safepoint_poll()

define void @idem(i64 %n) "java-method" {
entry:
  br label %h

h:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %lat ]
  %c = icmp slt i64 %iv, %n
  br i1 %c, label %b, label %x

b:
  %iv.next = add i64 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 5, i64 %iv.next) ]
  br label %lat

lat:
  br label %h

x:
  ret void
}

!java-method-compilation = !{}

; The strip-mine structure is present (so this isn't a "didn't strip" false pass)
; CHECK-LABEL: @idem(
; CHECK:       b.outer.inner.entry:
; CHECK:         %outer.batch.dist = sub nsw i128
; CHECK:         call i128 @llvm.smin.i128
; CHECK:         %outer.inner.limit = add nsw i64 %outer.iv, %outer.batch.chunk

; ...and exactly one coverage poll survives two runs — no second wrap.
; CHECK-COUNT-1: call hotspotcc void @jeandle.safepoint_poll()
; CHECK-NOT:     call hotspotcc void @jeandle.safepoint_poll
