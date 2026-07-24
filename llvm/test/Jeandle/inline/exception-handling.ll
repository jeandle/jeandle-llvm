; RUN: opt -S -passes=jeandle-inline-driver -jeandle-vm-callback-log=%S/Inputs/exception-handling.cblog %s 2>&1 | FileCheck %s

; The replayed callee has EH control flow. Inlining through an invoke should
; keep the root's unwind path and clone any missing helper declarations from
; the replay module.

@jeandle.personality = global ptr null

define hotspotcc i32 @root() #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %OrigPcSlot = alloca i64, align 8
  %result = invoke hotspotcc i32 @callee_with_eh() #2 [ "deopt"(i32 7, i32 7, i64 327695, ptr %OrigPcSlot) ]
          to label %normal unwind label %unwind

normal:
  ret i32 %result

unwind:
  %lp = landingpad i64
          cleanup
  ret i32 -1
}

declare hotspotcc i32 @callee_with_eh() #1 gc "hotspotgc"

attributes #0 = { "java-method"="3" }
attributes #1 = { "java-method"="103" }
attributes #2 = { "monomorphic-target" }

!java-method-compilation = !{}
!static-call-patch-size = !{!0}
!dynamic-call-patch-size = !{!1}

!0 = !{i32 5}
!1 = !{i32 15}

; CHECK-LABEL: define hotspotcc i32 @root(
; CHECK-NOT: @callee_with_eh
; CHECK: invoke hotspotcc void @leaf_may_throw()
; CHECK-NEXT: to label %{{.*}} unwind label %[[UNWIND:.*]]
; CHECK-NOT: @callee_with_eh
; CHECK: [[UNWIND]]:
; CHECK-NEXT: %{{.*}} = landingpad i64
; CHECK: br label %{{.*}}
; CHECK: phi i32 [ -1, %{{.*}} ], [ 42, %{{.*}} ]
; CHECK: ret i32
; CHECK: declare hotspotcc void @leaf_may_throw()
; CHECK-NOT: @callee_with_eh
; CHECK-NOT: define available_externally hotspotcc i32 @callee_with_eh
