; RUN: opt -passes='loop-simplify,lcssa,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,loop-unroll,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-loop-strip-mining-iter=8 \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -verify-each -S < %s \
; RUN:   | FileCheck %s --check-prefix=UNROLL
; RUN: opt -passes='loop-simplify,lcssa,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,loop-versioning-licm,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-loop-strip-mining-iter=8 \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -verify-each -S < %s \
; RUN:   | FileCheck %s --check-prefix=VERSION
; RUN: opt -passes='loop-simplify,lcssa,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,loop-rotate,verify<jeandle-safepoint-coverage>' \
; RUN:   -jeandle-loop-strip-mining-iter=8 \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -verify-each -S < %s \
; RUN:   | FileCheck %s --check-prefix=ROTATE

; Standard loop transforms run after Jeandle's early strip mining in the
; production O3 pipeline. The bounded poll-free inner loop may be unrolled or
; memory-versioned, and the outer loop may be rotated, but every resulting inner
; loop must remain enclosed by the marked outer-latch poll. The fatal coverage
; verifier makes that relationship part of this regression test instead of
; relying only on textual shape checks.

declare hotspotcc void @jeandle.safepoint_poll()

define void @unroll_after_strip_mining(ptr %a, i32 %n) "java-method" {
entry:
  %positive = icmp sgt i32 %n, 0
  br i1 %positive, label %preheader, label %exit

preheader:
  br label %loop

loop:
  %iv = phi i32 [ 0, %preheader ], [ %iv.next, %loop ]
  %address = getelementptr i32, ptr %a, i32 %iv
  store i32 %iv, ptr %address, align 4
  %iv.next = add nuw nsw i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %continue = icmp slt i32 %iv.next, %n
  br i1 %continue, label %loop, label %exit, !llvm.loop !0

exit:
  ret void
}

; UNROLL-LABEL: @unroll_after_strip_mining(
; UNROLL:       loop:
; UNROLL:       store i32
; UNROLL:       store i32
; UNROLL:       store i32
; UNROLL:       store i32
; UNROLL:       loop.outer:
; UNROLL:       loop.outer.latch:
; UNROLL:       call hotspotcc void @jeandle.safepoint_poll() #[[POLL:[0-9]+]]
; UNROLL:       attributes #[[POLL]] = { "jeandle.strip-mined-poll" }

; LoopRotate may move the outer exit test onto the outer latch. The marked poll
; must remain immediately on that backedge path.
; ROTATE-LABEL: @unroll_after_strip_mining(
; ROTATE:       loop.outer.latch:
; ROTATE:         call hotspotcc void @jeandle.safepoint_poll() #[[RPOLL:[0-9]+]]
; ROTATE-NEXT:    %outer.cond = icmp
; ROTATE:         br i1 %outer.cond
; ROTATE:       attributes #[[RPOLL]] = { "jeandle.strip-mined-poll" }

define void @version_licm_after_strip_mining(ptr %a, ptr %invariant,
                                             i32 %n) "java-method" {
entry:
  %positive = icmp sgt i32 %n, 0
  br i1 %positive, label %preheader, label %exit

preheader:
  br label %loop

loop:
  %iv = phi i32 [ 0, %preheader ], [ %iv.next, %loop ]
  %value = load i32, ptr %invariant, align 4
  %address = getelementptr i32, ptr %a, i32 %iv
  store i32 %value, ptr %address, align 4
  %iv.next = add nuw nsw i32 %iv, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 %iv.next) ]
  %continue = icmp slt i32 %iv.next, %n
  br i1 %continue, label %loop, label %exit

exit:
  ret void
}

; VERSION-LABEL: @version_licm_after_strip_mining(
; VERSION:       loop:
; VERSION:       store i32 {{.*}} !noalias
; VERSION:       loop.outer:
; VERSION:       loop.lver.check:
; VERSION:       loop.ph.lver.orig:
; VERSION:       loop.lver.orig:
; VERSION:       store i32
; VERSION:       loop.outer.latch:
; VERSION:       call hotspotcc void @jeandle.safepoint_poll() #[[VPOLL:[0-9]+]]
; VERSION:       attributes #[[VPOLL]] = { "jeandle.strip-mined-poll" }

!java-method-compilation = !{}

!0 = distinct !{!0, !1}
!1 = !{!"llvm.loop.unroll.count", i32 4}
