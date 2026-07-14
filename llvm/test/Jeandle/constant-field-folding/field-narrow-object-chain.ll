; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/field-narrow-object-chain.cblog %s 2>&1 | FileCheck %s

; Oop-chain across an addrspacecast in compressed-oops mode. A constant
; narrow-oop field is read and decoded to the wide heap address space, then a
; second (int) field is loaded through the decoded wide oop. The constant oop
; id must propagate across the encode+decode cast pair so the second field
; folds too. This is the marquee test for "constant oop propagates across
; addrspacecast".

@oop_handle_Root_0 = external global ptr addrspace(1)

define i32 @test() gc "hotspotgc" {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Root_0
  %child.addr = getelementptr i8, ptr addrspace(1) %base, i64 16
  %child.narrow = load ptr addrspace(3), ptr addrspace(1) %child.addr
  %child = addrspacecast ptr addrspace(3) %child.narrow to ptr addrspace(1)
  %value.addr = getelementptr i8, ptr addrspace(1) %child, i64 20
  %value = load i32, ptr addrspace(1) %value.addr
  ret i32 %value
}

; CHECK: @oop_handle_Child_1 = external dso_local global ptr addrspace(1)
; CHECK: ret i32 7

!java-method-compilation = !{}
