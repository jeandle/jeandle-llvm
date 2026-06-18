; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/field-zero-gep.cblog %s 2>&1 | FileCheck %s

; A zero-index GEP between the handle load and the field GEP should be
; transparent to the ConstOop lattice.

@oop_handle_Test_0 = external global ptr addrspace(1)

define i32 @test() gc "hotspotgc" {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Test_0
  %zero = getelementptr i8, ptr addrspace(1) %base, i64 0
  %addr = getelementptr i8, ptr addrspace(1) %zero, i64 12
  %value = load i32, ptr addrspace(1) %addr
  ret i32 %value
}

; CHECK: ret i32 42

!java-method-compilation = !{}
