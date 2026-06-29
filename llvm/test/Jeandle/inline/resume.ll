; RUN: opt -S -passes=jeandle-inline-driver -jeandle-vm-callback-log=%S/Inputs/resume.cblog %s 2>&1 | FileCheck %s

; Callee IR can unwind with either a normal landingpad value or a dummy zero
; resume value. Both forms should be redirected to the caller landingpad when
; the callee is inlined through an invoke.

@jeandle.personality = global ptr null

define hotspotcc i32 @root() #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %OrigPcSlot = alloca i64, align 8
  invoke hotspotcc void @callee_resume_landingpad() #3 [ "deopt"(i32 13, i32 13, i64 327695, ptr %OrigPcSlot) ]
          to label %after_landingpad unwind label %root_unwind

after_landingpad:
  invoke hotspotcc void @callee_resume_zero() #3 [ "deopt"(i32 17, i32 17, i64 327695, ptr %OrigPcSlot) ]
          to label %normal unwind label %root_unwind

normal:
  ret i32 0

root_unwind:
  %lp = landingpad i64
          cleanup
  ret i32 -1
}

declare hotspotcc void @callee_resume_landingpad() #1 gc "hotspotgc"
declare hotspotcc void @callee_resume_zero() #2 gc "hotspotgc"

attributes #0 = { "java-method"="5" }
attributes #1 = { "java-method"="105" }
attributes #2 = { "java-method"="106" }
attributes #3 = { "monomorphic-target" }

!java-method-compilation = !{}

; CHECK-LABEL: define hotspotcc i32 @root(
; CHECK-NOT: @callee_resume_landingpad
; CHECK: invoke hotspotcc void @leaf_resume_landingpad()
; CHECK-NEXT: to label %{{.*}} unwind label %[[INNER_UNWIND:.*]]
; CHECK-NOT: @callee_resume_landingpad
; CHECK: [[INNER_UNWIND]]:
; CHECK: landingpad i64
; CHECK: br label %root_unwind
; CHECK: after_landingpad:
; CHECK-NEXT: br label %root_unwind
; CHECK: root_unwind:
; CHECK: landingpad i64
; CHECK: root_unwind.body1:
; CHECK-NOT: phi i64
; CHECK: ret i32 -1
; CHECK-NOT: define available_externally hotspotcc void @callee_resume_landingpad
; CHECK-NOT: define available_externally hotspotcc void @callee_resume_zero
