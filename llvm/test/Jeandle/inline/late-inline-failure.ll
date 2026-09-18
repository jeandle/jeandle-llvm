; RUN: opt -S -passes=jeandle-inline-driver -jeandle-vm-callback-log=%S/Inputs/late-inline-failure.cblog %s 2>&1 | FileCheck %s

; A late-inline call that cannot be inlined must become noinline. Its marker is
; sticky during the driver, so leaving the call eligible would retry the same
; terminal failure in every later round.

@jeandle.personality = global ptr null

define hotspotcc i32 @root() #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %OrigPcSlot = alloca i64, align 8
  %result = call hotspotcc i32 @late_callee() #2 [ "deopt"(i32 7, i32 7, i64 327695, ptr %OrigPcSlot) ]
  ret i32 %result
}

declare hotspotcc i32 @late_callee() #1 gc "hotspotgc"

attributes #0 = { "java-method"="4" }
attributes #1 = { "java-method"="104" }
attributes #2 = { "monomorphic-target" }

!java-method-compilation = !{}

; CHECK-LABEL: define hotspotcc i32 @root(
; CHECK: call hotspotcc i32 @late_callee() #[[CALL_ATTRS:[0-9]+]]
; CHECK: attributes #[[CALL_ATTRS]] = { noinline "monomorphic-target" }
