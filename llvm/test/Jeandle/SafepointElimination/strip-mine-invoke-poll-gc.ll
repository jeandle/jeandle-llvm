; RUN: opt -passes='loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>,verify' \
; RUN:   -verify-each -S < %s | FileCheck %s --check-prefix=STRIP
; RUN: opt -passes='function(loop-simplify,lcssa,loop-rotate,safepoint-poll-elimination<early>,safepoint-strip-mining<strip-mining>,safepoint-poll-elimination<after-strip-mining>),java-operation-lower<phase=1>,rewrite-statepoints-for-gc,verify' \
; RUN:   -verify-each -S < %s | FileCheck %s --check-prefix=GC \
; RUN:   --implicit-check-not='invoke hotspotcc void @jeandle.safepoint_poll'

; Complement the invoke CFG tests with the existing JavaOp-lowering/RS4GC
; contract. The object is live on both normal and exceptional continuations.
; The external token landingpad initially has no PHI, so it is within the
; candidate's supported relocation domain. The poll's deopt state describes
; the next IV/reduction, not the old inner-header state.
;
; The private phase-1 stub follows strip-mine-deopt-next-remap.ll. It is a
; controlled lowering fixture, not a substitute for the production template
; or a runtime async-exception/GC-relocation test.

declare hotspotcc void @safepoint_handler()

define private hotspotcc void @jeandle.safepoint_poll() #0 {
entry:
  call hotspotcc void @safepoint_handler() [ "deopt"() ]
  ret void
}

define ptr addrspace(1) @invoke_live_object(i64 noundef %n,
                                          ptr addrspace(1) %obj) "java-method"
    gc "hotspotgc" personality ptr null {
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
      [ "deopt"(i32 41, ptr addrspace(1) %obj, i64 %sum.next, i64 %iv.next) ]
      to label %latch unwind label %unwind
latch:
  %more = icmp slt i64 %iv.next, %n
  br i1 %more, label %header, label %exit
unwind:
  %exception = landingpad token cleanup
  ret ptr addrspace(1) %obj
exit:
  ret ptr addrspace(1) %obj
empty:
  ret ptr addrspace(1) %obj
}

!java-method-compilation = !{}

attributes #0 = { "lower-phase"="1" "noinline" }

; Relocation itself must happen before testing downstream GC state. The old
; invoke normal edge becomes an ordinary branch; the single external EH exit
; remains and the new outer invoke carries batch-boundary state.
; STRIP-LABEL: define ptr addrspace(1) @invoke_live_object(
; STRIP:       header:
; STRIP-NOT:     @jeandle.safepoint_poll
; STRIP:         br label %latch
; STRIP:       unwind:
; STRIP-NEXT:    %exception = landingpad token
; STRIP:         ret ptr addrspace(1) %obj
; STRIP:       header.outer.latch:
; STRIP:         %[[NEXT_IV:[-a-zA-Z$._0-9]+]] = phi i64 [ %iv.next, %latch ]
; STRIP:         %[[NEXT_SUM:[-a-zA-Z$._0-9]+]] = phi i64 [ %sum.next, %latch ]
; STRIP:         invoke hotspotcc void @jeandle.safepoint_poll() {{.*}}[ "deopt"(i32 41, ptr addrspace(1) %obj, i64 %[[NEXT_SUM]], i64 %[[NEXT_IV]]) ]
; STRIP-NEXT:      to label %header.outer unwind label %unwind

; RS4GC can print exceptional blocks before the appended outer loop. DAGs
; avoid depending on that textual order while binding both relocations to
; their distinct, correct tokens and binding the live oop to the next batch.
; RS4GC removes the single-input LCSSA PHIs, so bind the original next-value
; definitions rather than requiring those redundant PHIs to survive.
; GC-LABEL: define ptr addrspace(1) @invoke_live_object(
; GC-DAG: %[[GC_NEXT_IV:[-a-zA-Z$._0-9]+]] = add nsw i64 %iv, 1
; GC-DAG: %[[GC_NEXT_SUM:[-a-zA-Z$._0-9]+]] = add i64 %sum, %iv
; GC-DAG: %[[STATEPOINT:[-a-zA-Z$._0-9]+]] = invoke hotspotcc token {{.*}}@llvm.experimental.gc.statepoint.p0({{.*}}@safepoint_handler{{.*}}[ "deopt"(i32 41, ptr addrspace(1) %[[LIVE:[-a-zA-Z$._0-9]+]], i64 %[[GC_NEXT_SUM]], i64 %[[GC_NEXT_IV]]), "gc-live"(ptr addrspace(1) %[[LIVE]]) ]
; GC-DAG: to label %[[NORMAL:[-a-zA-Z$._0-9]+]] unwind label %unwind
; GC-DAG: %[[NORMAL_OBJ:[-a-zA-Z$._0-9]+]] = call coldcc ptr addrspace(1) @llvm.experimental.gc.relocate.p1(token %[[STATEPOINT]], i32 0, i32 0)
; GC-DAG: %[[LIVE]] = phi ptr addrspace(1) [ %obj, %{{[-a-zA-Z$._0-9]+}} ], [ %[[NORMAL_OBJ]], %[[NORMAL]] ]
; GC-DAG: %[[LANDINGPAD:[-a-zA-Z$._0-9]+]] = landingpad token
; GC-DAG: %[[EXCEPTION_OBJ:[-a-zA-Z$._0-9]+]] = call coldcc ptr addrspace(1) @llvm.experimental.gc.relocate.p1(token %[[LANDINGPAD]], i32 0, i32 0)
; GC-DAG: ret ptr addrspace(1) %[[EXCEPTION_OBJ]]
