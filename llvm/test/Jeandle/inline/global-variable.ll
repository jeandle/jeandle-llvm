; RUN: opt -S -passes=jeandle-inline-driver -jeandle-vm-callback-log=%S/Inputs/global-variable.cblog %s 2>&1 | FileCheck %s

; The replayed callee references a GlobalVariable that is absent from this
; module. JeandleInliner should clone that dependency on demand and inline the
; callee body into the root method.

@jeandle.personality = global ptr null

define hotspotcc i32 @root() #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %OrigPcSlot = alloca i64, align 8
  %result = call hotspotcc i32 @callee_global_variable() #2 [ "deopt"(i32 0, i32 0, i64 327695, ptr %OrigPcSlot) ]
  ret i32 %result
}

declare hotspotcc i32 @callee_global_variable() #1 gc "hotspotgc"

attributes #0 = { "java-method"="1" }
attributes #1 = { "java-method"="101" }
attributes #2 = { "monomorphic-target" }

!java-method-compilation = !{}

; CHECK: @inline.global = private global i32 41
; CHECK-LABEL: define hotspotcc i32 @root(
; CHECK-NOT: @callee_global_variable
; CHECK: load i32, ptr @inline.global
; CHECK-NOT: @callee_global_variable
; CHECK: add i32 {{.*}}, 1
; CHECK-NOT: @callee_global_variable
; CHECK: ret i32
; CHECK-NOT: define available_externally hotspotcc i32 @callee_global_variable
