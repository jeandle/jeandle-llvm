; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/field-no-gep.cblog %s 2>&1 | FileCheck %s

; The load's pointer is directly a ConstOop (no intermediate GEP). The
; VM callback is queried at offset 0; if it is foldable, the load is
; replaced.

@oop_handle_Test_0 = external global ptr addrspace(1)

define i32 @test() gc "hotspotgc" {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Test_0
  %value = load i32, ptr addrspace(1) %base
  ret i32 %value
}

; CHECK: ret i32 42

!java-method-compilation = !{}
