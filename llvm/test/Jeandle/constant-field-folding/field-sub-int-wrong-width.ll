; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/field-sub-int-wrong-width.cblog %s 2>&1 | FileCheck %s

; A T_BOOLEAN field should be loaded as i8 in memory. If the IR loads it
; as a different width (e.g., i32), the widened value returned by the VM
; will not match the actual memory contents at that offset, so the pass
; conservatively refuses to fold. (Defensive — frontend currently always
; uses i8/i16 for sub-int fields, but the pass must not assume so.)

@oop_handle_Test_0 = external global ptr addrspace(1)

define i32 @test() gc "hotspotgc" {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Test_0
  %addr = getelementptr i8, ptr addrspace(1) %base, i64 12
  %value = load i32, ptr addrspace(1) %addr
  ret i32 %value
}

; CHECK: %value = load i32, ptr addrspace(1) %addr
; CHECK: ret i32 %value

!java-method-compilation = !{}
