; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/field-gep-multi-index.cblog %s 2>&1 | FileCheck %s

; GEP with multiple constant indices summing to byte offset 12.
; [3 x i32] index (1, 0) = 1 * 12 + 0 * 4 = 12.

@oop_handle_Test_0 = external global ptr addrspace(1)

define i32 @test() gc "hotspotgc" {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Test_0
  %addr = getelementptr [3 x i32], ptr addrspace(1) %base, i64 1, i64 0
  %value = load i32, ptr addrspace(1) %addr
  ret i32 %value
}

; CHECK: ret i32 42

!java-method-compilation = !{}
