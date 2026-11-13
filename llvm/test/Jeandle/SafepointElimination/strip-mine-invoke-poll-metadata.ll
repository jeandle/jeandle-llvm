; RUN: opt -passes='loop-simplify,lcssa,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,verify<domtree>,verify<loops>,safepoint-poll-elimination<after-strip-mining>,verify<domtree>,verify<loops>,verify<jeandle-safepoint-coverage>,verify' \
; RUN:   -jeandle-verify-safepoint-coverage=fatal -verify-each -S < %s | FileCheck %s

; The input is already the rotated, pre-tested form produced before strip
; mining: a positive entry guard, next-IV latch compare and external EH exit.
; Check ordinary loop-hint ownership independently of the new outer poll.
; Also exercise two invoke polls sharing one PHI-free landingpad: relocating
; the later poll and deleting the earlier inner poll must remove both old EH
; predecessors, leaving exactly the new outer-latch predecessor.

declare hotspotcc void @jeandle.safepoint_poll()

define i64 @invoke_loop_hints(i64 noundef %n) "java-method" personality ptr null !dbg !10 {
entry:
  %has.work = icmp sgt i64 %n, 0
  br i1 %has.work, label %preheader, label %empty
preheader:
  br label %header
header:
  %iv = phi i64 [ 0, %preheader ], [ %iv.next, %latch ]
  %sum = phi i64 [ 0, %preheader ], [ %sum.next, %latch ]
  %sum.next = add i64 %sum, %iv
  %iv.next = add nsw i64 %iv, 1
  invoke hotspotcc void @jeandle.safepoint_poll() #0
      [ "deopt"(i64 %sum.next, i64 %iv.next) ]
      to label %latch unwind label %unwind, !prof !5, !dbg !13
latch:
  %more = icmp slt i64 %iv.next, %n
  br i1 %more, label %header, label %exit, !llvm.loop !0
unwind:
  %exception = landingpad i64 cleanup
  ret i64 -1
exit:
  %result = phi i64 [ %sum.next, %latch ]
  ret i64 %result
empty:
  ret i64 0
}

; CHECK-LABEL: define i64 @invoke_loop_hints(
; CHECK:       header:
; CHECK-NOT:     @jeandle.safepoint_poll
; CHECK:         br label %latch
; CHECK:       latch:
; CHECK:         br i1 %more, label %header, label %header.outer.latch, !llvm.loop ![[HINT_LOOP:[0-9]+]]
; CHECK:       unwind:
; CHECK-SAME:     preds = %header.outer.latch
; CHECK:       header.outer.latch:
; CHECK:         invoke hotspotcc void @jeandle.safepoint_poll() #[[POLL_ATTR:[0-9]+]]
; CHECK-NEXT:      to label %header.outer unwind label %unwind, !dbg ![[POLL_DBG:[0-9]+]], !prof ![[POLL_WEIGHTS:[0-9]+]]

define i64 @two_invoke_polls_shared_landingpad(i64 noundef %n) "java-method"
    personality ptr null {
entry:
  %has.work = icmp sgt i64 %n, 0
  br i1 %has.work, label %preheader, label %empty
preheader:
  br label %header
header:
  %iv = phi i64 [ 0, %preheader ], [ %iv.next, %latch ]
  %sum = phi i64 [ 0, %preheader ], [ %sum.next, %latch ]
  %sum.next = add i64 %sum, %iv
  %iv.next = add nsw i64 %iv, 1
  invoke hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i64 %sum.next, i64 %iv.next) ]
      to label %second.poll unwind label %unwind
second.poll:
  invoke hotspotcc void @jeandle.safepoint_poll()
      [ "deopt"(i64 %sum.next, i64 %iv.next) ]
      to label %latch unwind label %unwind
latch:
  %more = icmp slt i64 %iv.next, %n
  br i1 %more, label %header, label %exit
unwind:
  %exception = landingpad i64 cleanup
  ret i64 -1
exit:
  %result = phi i64 [ %sum.next, %latch ]
  ret i64 %result
empty:
  ret i64 0
}

; CHECK-LABEL: define i64 @two_invoke_polls_shared_landingpad(
; CHECK:       header:
; CHECK-NOT:     @jeandle.safepoint_poll
; CHECK:         br label %second.poll
; CHECK:       second.poll:
; CHECK-NEXT:    br label %latch
; CHECK:       latch:
; CHECK-NOT:     @jeandle.safepoint_poll
; CHECK:         br i1 %more, label %header, label %header.outer.latch
; CHECK:       unwind:
; CHECK-SAME:     preds = %header.outer.latch
; CHECK-NEXT:    %exception = landingpad i64
; CHECK:       header.outer.latch:
; CHECK:         invoke hotspotcc void @jeandle.safepoint_poll() #[[SECOND_POLL_ATTR:[0-9]+]] [ "deopt"(i64 %sum.outer.next, i64 %outer.iv.next) ]
; CHECK-NEXT:      to label %header.outer unwind label %unwind
; CHECK-NOT:     @jeandle.safepoint_poll
; CHECK:       }

; The invoke itself is not the loop's latch in this shape. An unexpected old
; loop attachment on it is not an ordinary latch hint to copy onto the new
; outer backedge. Decline without mutating that attachment or either EH edge.
define void @invoke_with_old_loop_attachment(i64 noundef %n) "java-method"
    personality ptr null {
entry:
  %has.work = icmp sgt i64 %n, 0
  br i1 %has.work, label %preheader, label %exit
preheader:
  br label %header
header:
  %iv = phi i64 [ 0, %preheader ], [ %iv.next, %latch ]
  %iv.next = add nsw i64 %iv, 1
  invoke hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
      to label %latch unwind label %unwind, !llvm.loop !3
latch:
  %more = icmp slt i64 %iv.next, %n
  br i1 %more, label %header, label %exit.loop
unwind:
  %exception = landingpad i64 cleanup
  ret void
exit.loop:
  ret void
exit:
  ret void
}

; CHECK-LABEL: define void @invoke_with_old_loop_attachment(
; CHECK-NOT:   .outer
; CHECK:       invoke hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 %iv.next) ]
; CHECK-NEXT:    to label %latch unwind label %unwind, !llvm.loop ![[OLD_LOOP:[0-9]+]]
; CHECK-NOT:   .outer
; CHECK:       }

attributes #0 = { "invoke-poll-test" }
!java-method-compilation = !{}
!llvm.dbg.cu = !{!6}
!llvm.module.flags = !{!14}
!0 = distinct !{!0, !1, !2}
!1 = !{!"llvm.loop.vectorize.enable", i1 true}
!2 = !{!"llvm.loop.unroll.disable"}
!3 = distinct !{!3, !4}
!4 = !{!"llvm.loop.vectorize.enable", i1 false}
!5 = !{!"branch_weights", i32 2000, i32 1}
!6 = distinct !DICompileUnit(language: DW_LANG_C, file: !7, producer: "invoke-poll-test", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug)
!7 = !DIFile(filename: "invoke-poll-test.c", directory: "/")
!8 = !DISubroutineType(types: !9)
!9 = !{}
!10 = distinct !DISubprogram(name: "invoke_loop_hints", scope: !7, file: !7, line: 1, type: !8, scopeLine: 1, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !6)
!13 = !DILocation(line: 17, column: 3, scope: !10)
!14 = !{i32 2, !"Debug Info Version", i32 3}

; CHECK: attributes #[[POLL_ATTR]] = { {{.*}}"invoke-poll-test"{{.*}}"jeandle.strip-mined-poll"{{.*}} }
; CHECK: attributes #[[SECOND_POLL_ATTR]] = { {{.*}}"jeandle.strip-mined-poll"{{.*}} }
; CHECK-DAG: ![[HINT_LOOP]] = distinct !{![[HINT_LOOP]], ![[VECTOR_HINT:[0-9]+]], ![[UNROLL_HINT:[0-9]+]]}
; CHECK-DAG: ![[VECTOR_HINT]] = !{!"llvm.loop.vectorize.enable", i1 true}
; CHECK-DAG: ![[UNROLL_HINT]] = !{!"llvm.loop.unroll.disable"}
; CHECK-DAG: ![[OLD_LOOP]] = distinct !{![[OLD_LOOP]], ![[OLD_VECTOR_HINT:[0-9]+]]}
; CHECK-DAG: ![[OLD_VECTOR_HINT]] = !{!"llvm.loop.vectorize.enable", i1 false}
; CHECK-DAG: ![[POLL_DBG]] = !DILocation(line: 17, column: 3,
; CHECK-DAG: ![[POLL_WEIGHTS]] = !{!"branch_weights", i32 2000, i32 1}
