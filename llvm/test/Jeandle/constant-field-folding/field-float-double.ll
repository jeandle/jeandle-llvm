; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/field-float-double.cblog %s 2>&1 | FileCheck %s

@oop_handle_Test_0 = external global ptr addrspace(1)

define float @test_float() gc "hotspotgc" {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Test_0
  %addr = getelementptr i8, ptr addrspace(1) %base, i64 32
  %value = load float, ptr addrspace(1) %addr
  ret float %value
}

define double @test_double() gc "hotspotgc" {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Test_0
  %addr = getelementptr i8, ptr addrspace(1) %base, i64 40
  %value = load double, ptr addrspace(1) %addr
  ret double %value
}

; CHECK: ret float -1.000000e+00
; CHECK: ret double -1.000000e+00

!java-method-compilation = !{}
