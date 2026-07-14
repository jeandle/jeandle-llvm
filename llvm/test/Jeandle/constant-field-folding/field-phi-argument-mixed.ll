; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/field-phi-argument-mixed.cblog %s 2>&1 | FileCheck %s

; An oop-typed argument is an opaque producer. Even if it flows through
; PHIs and is later merged with a constant oop, the merged value must not be
; treated as the constant oop. Otherwise CFF may fold a field load from a
; runtime argument as if it came from @oop_handle_Test_0.

@oop_handle_Test_0 = external global ptr addrspace(1)

define i32 @test(ptr addrspace(1) %arg0, ptr addrspace(1) %arg1,
                 i1 %choose.arg, i1 %choose.const) gc "hotspotgc" {
entry:
  br i1 %choose.arg, label %arg.left, label %arg.right

arg.left:
  br label %arg.merge

arg.right:
  br label %arg.merge

arg.merge:
  %arg.obj = phi ptr addrspace(1) [ %arg0, %arg.left ], [ %arg1, %arg.right ]
  br i1 %choose.const, label %const.path, label %arg.path

const.path:
  %const.obj = load ptr addrspace(1), ptr @oop_handle_Test_0
  br label %merge

arg.path:
  br label %merge

merge:
  %merged = phi ptr addrspace(1) [ %const.obj, %const.path ], [ %arg.obj, %arg.path ]
  %addr = getelementptr i8, ptr addrspace(1) %merged, i64 12
  %value = load i32, ptr addrspace(1) %addr
  ret i32 %value
}

; CHECK-LABEL: define i32 @test(
; CHECK: %arg.obj = phi
; CHECK: %merged = phi
; CHECK: %addr = getelementptr
; CHECK: %value = load i32, ptr addrspace(1) %addr
; CHECK: ret i32 %value

!java-method-compilation = !{}
