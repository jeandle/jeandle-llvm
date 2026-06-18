; RUN: opt -S -passes="constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/field-sub-int.cblog %s 2>&1 | FileCheck %s

@oop_handle_Test_0 = external global ptr addrspace(1)

define i32 @fold_boolean() gc "hotspotgc" {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Test_0
  %addr = getelementptr i8, ptr addrspace(1) %base, i64 4
  %raw = load i8, ptr addrspace(1) %addr
  %value = zext i8 %raw to i32
  ret i32 %value
}

define i32 @fold_byte() gc "hotspotgc" {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Test_0
  %addr = getelementptr i8, ptr addrspace(1) %base, i64 8
  %raw = load i8, ptr addrspace(1) %addr
  %value = sext i8 %raw to i32
  ret i32 %value
}

define i32 @fold_char() gc "hotspotgc" {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Test_0
  %addr = getelementptr i8, ptr addrspace(1) %base, i64 12
  %raw = load i16, ptr addrspace(1) %addr
  %value = zext i16 %raw to i32
  ret i32 %value
}

define i32 @fold_short() gc "hotspotgc" {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Test_0
  %addr = getelementptr i8, ptr addrspace(1) %base, i64 16
  %raw = load i16, ptr addrspace(1) %addr
  %value = sext i16 %raw to i32
  ret i32 %value
}

; CHECK-LABEL: @fold_boolean(
; CHECK: ret i32 1
; CHECK-LABEL: @fold_byte(
; CHECK: ret i32 -1
; CHECK-LABEL: @fold_char(
; CHECK: ret i32 65535
; CHECK-LABEL: @fold_short(
; CHECK: ret i32 -2

!java-method-compilation = !{}
