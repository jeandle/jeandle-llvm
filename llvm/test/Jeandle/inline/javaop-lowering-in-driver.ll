; RUN: opt -S -passes=jeandle-inline-driver -jeandle-vm-callback-log=%S/Inputs/javaop-lowering-in-driver.cblog %s 2>&1 | FileCheck %s

; Verify the inline driver lowers phase-0 JavaOp calls introduced by an inlined
; callee body. @callee_example is inlined into @root; the in-driver
; JavaOperationLower(0) round then lowers the new call to the phase-0 JavaOp
; @jeandle.example_op, so @root ends up with the JavaOp body inlined and no
; call to it. The JavaOp definition itself remains in the module: the driver
; does not erase JavaOps (deletion is deferred to the JavaOperationDeletion pass,
; which the driver does not run).

@jeandle.personality = global ptr null

define hotspotcc i32 @root() #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %OrigPcSlot = alloca i64, align 8
  %result = call hotspotcc i32 @callee_example() #2 [ "deopt"(i32 0, i32 0, i64 327695, ptr %OrigPcSlot) ]
  ret i32 %result
}

declare hotspotcc i32 @callee_example() #1 gc "hotspotgc"

; A phase-0 JavaOp whose body the in-driver JavaOperationLower(0) inlines into
; @root once @callee_example is inlined there.
define private hotspotcc i32 @jeandle.example_op() #3 {
  ret i32 4242
}

attributes #0 = { "java-method"="1" }
attributes #1 = { "java-method"="101" }
attributes #2 = { "monomorphic-target" }
attributes #3 = { "lower-phase"="0" "noinline" }

!java-method-compilation = !{}

; CHECK-LABEL: define hotspotcc i32 @root(
; The inlined JavaOp call is gone from @root, replaced by its body.
; CHECK-NOT: call {{.*}} @jeandle.example_op
; CHECK: 4242
; The phase-0 JavaOp definition survives the driver (deletion is deferred).
; CHECK: define private hotspotcc i32 @jeandle.example_op
; The available_externally callee body is cleaned up by the driver.
; CHECK-NOT: define available_externally hotspotcc i32 @callee_example
