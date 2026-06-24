; RUN: opt -S -passes=jeandle-inline-driver -jeandle-vm-callback-log=%S/Inputs/policy-denied.cblog %s 2>&1 | FileCheck %s

; If the VM policy callback rejects a call site, the inliner should leave it
; untouched and must not request callee IR.

@jeandle.personality = global ptr null

define hotspotcc i32 @root() #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %OrigPcSlot = alloca i64, align 8
  %result = call hotspotcc i32 @callee_policy_denied() #2 [ "deopt"(i32 11, i32 11, i64 327695, ptr %OrigPcSlot) ]
  ret i32 %result
}

declare hotspotcc i32 @callee_policy_denied() #1 gc "hotspotgc"

attributes #0 = { "java-method"="4" }
attributes #1 = { "java-method"="104" }
attributes #2 = { "monomorphic-target" }

!java-method-compilation = !{}

; CHECK-LABEL: define hotspotcc i32 @root(
; CHECK: call hotspotcc i32 @callee_policy_denied
; CHECK: ret i32
