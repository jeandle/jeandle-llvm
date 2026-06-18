; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/field-phi-mixed.cblog %s 2>&1 | FileCheck %s

@oop_handle_Test_0 = external global ptr addrspace(1)
@runtime_oop = external global ptr addrspace(1)

define i32 @test(i1 %cond) gc "hotspotgc" {
entry:
  %const.base = load ptr addrspace(1), ptr @oop_handle_Test_0
  %runtime.base = load ptr addrspace(1), ptr @runtime_oop
  br i1 %cond, label %left, label %right

left:
  br label %merge

right:
  br label %merge

merge:
  %merged = phi ptr addrspace(1) [ %const.base, %left ], [ %runtime.base, %right ]
  %addr = getelementptr i8, ptr addrspace(1) %merged, i64 12
  %value = load i32, ptr addrspace(1) %addr
  ret i32 %value
}

; CHECK: %value = load i32, ptr addrspace(1) %addr
; CHECK: ret i32 %value

!java-method-compilation = !{}
