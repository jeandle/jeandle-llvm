; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/field-object-chain-dedup.cblog %s 2>&1 | FileCheck %s

; When folding an oop chain, if the module already contains a global for
; the chained oop id, the pass should reuse it (via getOrInsertGlobal
; with the same descriptive name) rather than create a second global.
; This keeps the IR free of redundant globals that would defeat downstream
; CSE / alias analysis.

@oop_handle_Root_0 = external global ptr addrspace(1)
@oop_handle_Existing_1 = external global ptr addrspace(1)

define i32 @test() gc "hotspotgc" {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Root_0
  %child.addr = getelementptr i8, ptr addrspace(1) %base, i64 16
  %child = load ptr addrspace(1), ptr addrspace(1) %child.addr
  %value.addr = getelementptr i8, ptr addrspace(1) %child, i64 20
  %value = load i32, ptr addrspace(1) %value.addr
  ret i32 %value
}

; CHECK-LABEL: define i32 @test
; CHECK: load ptr addrspace(1), ptr @oop_handle_Existing_1
; CHECK: ret i32 7

!java-method-compilation = !{}
