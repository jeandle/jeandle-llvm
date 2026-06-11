; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/field-null-object.cblog %s 2>&1 | FileCheck %s

@oop_handle_Test_0 = external global ptr addrspace(1)

define ptr addrspace(1) @test() gc "hotspotgc" {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Test_0
  %addr = getelementptr i8, ptr addrspace(1) %base, i64 24
  %value = load ptr addrspace(1), ptr addrspace(1) %addr
  ret ptr addrspace(1) %value
}

; CHECK: ret ptr addrspace(1) null

!java-method-compilation = !{}
