; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/field-gep-non-i8.cblog %s 2>&1 | FileCheck %s

; Non-i8 GEP element type: byte offset must be scaled by element size.
; The old code read the index as a raw byte offset (3) and would have
; called the VM callback with offset 3 instead of 12.

@oop_handle_Test_0 = external global ptr addrspace(1)

define i32 @test() gc "hotspotgc" {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Test_0
  %addr = getelementptr i32, ptr addrspace(1) %base, i64 3
  %value = load i32, ptr addrspace(1) %addr
  ret i32 %value
}

; CHECK: ret i32 42

!java-method-compilation = !{}
