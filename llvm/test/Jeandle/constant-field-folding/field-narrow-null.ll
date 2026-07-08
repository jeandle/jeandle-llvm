; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/field-narrow-null.cblog %s 2>&1 | FileCheck %s

; A constant narrow-oop (compressed) field whose value is null must fold to a
; narrow null in the same address space (addrspace(3)).

@oop_handle_Test_0 = external global ptr addrspace(1)

define ptr addrspace(3) @test() gc "hotspotgc" {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Test_0
  %addr = getelementptr i8, ptr addrspace(1) %base, i64 24
  %value = load ptr addrspace(3), ptr addrspace(1) %addr
  ret ptr addrspace(3) %value
}

; CHECK: ret ptr addrspace(3) null

!java-method-compilation = !{}
