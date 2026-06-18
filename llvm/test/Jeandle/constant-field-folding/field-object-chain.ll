; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/field-object-chain.cblog %s 2>&1 | FileCheck %s

@oop_handle_Root_0 = external global ptr addrspace(1)

define i32 @test() gc "hotspotgc" {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Root_0
  %child.addr = getelementptr i8, ptr addrspace(1) %base, i64 16
  %child = load ptr addrspace(1), ptr addrspace(1) %child.addr
  %value.addr = getelementptr i8, ptr addrspace(1) %child, i64 20
  %value = load i32, ptr addrspace(1) %value.addr
  ret i32 %value
}

; CHECK: @oop_handle_Child_1 = external dso_local global ptr addrspace(1)
; CHECK: ret i32 7

!java-method-compilation = !{}
