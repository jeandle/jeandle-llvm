; RUN: opt -S -passes=jeandle-inline-driver -jeandle-vm-callback-log=%S/Inputs/late-inline.cblog %s 2>&1 | FileCheck %s

; The eager policy defers this call. The first late round processes the delayed
; callee, but its newly exposed ordinary child is queried with
; is_late_inline=false and delayed. A second late round processes that child
; only after another pre-late cleanup opportunity.

@jeandle.personality = global ptr null

define hotspotcc i32 @root() #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %OrigPcSlot = alloca i64, align 8
  %result = call hotspotcc i32 @late_callee() #2 [ "deopt"(i32 7, i32 7, i64 327695, ptr %OrigPcSlot) ]
  ret i32 %result
}

declare hotspotcc i32 @late_callee() #1 gc "hotspotgc"
declare hotspotcc i32 @late_child() #3 gc "hotspotgc"

attributes #0 = { "java-method"="4" }
attributes #1 = { "java-method"="104" }
attributes #2 = { "monomorphic-target" }
attributes #3 = { "java-method"="105" }

!java-method-compilation = !{}
!static-call-patch-size = !{!0}

!0 = !{i32 5}

; CHECK-LABEL: define hotspotcc i32 @root(
; CHECK-NOT: call hotspotcc i32 @late_callee
; CHECK-NOT: call hotspotcc i32 @late_child
; CHECK: ret i32 42
; CHECK-NOT: define available_externally hotspotcc i32 @late_callee
; CHECK-NOT: define available_externally hotspotcc i32 @late_child
