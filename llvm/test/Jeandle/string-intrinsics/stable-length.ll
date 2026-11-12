; RUN: opt -S -passes='string-intrinsic-specialization,repeated-constant-field-folding,string-intrinsic-specialization,repeated-constant-field-folding' -jeandle-vm-callback-log=%S/Inputs/stable-length.cblog -verify-each %s | FileCheck %s

; Model the existing two specialization opportunities. Counts come from
; arraylength operations, not explicit constants supplied by the test.
@arrayOopDesc.length_offset_in_bytes = private constant i32 12
@oop_handle_Stable_0 = external global ptr addrspace(1)
@oop_handle_Stable_1 = external global ptr addrspace(1)
@oop_handle_Mutable_2 = external global ptr addrspace(1)
declare i32 @jeandle.arraylength(ptr addrspace(1))
declare i32 @jeandle.string_compare(ptr addrspace(1), i32, ptr addrspace(1), i32, i32)
; CHECK-LABEL: @stable_compare(
; CHECK-NOT: call
; CHECK-NOT: load atomic
; CHECK: ret i32 -1
define i32 @stable_compare() {
  %a = load ptr addrspace(1), ptr @oop_handle_Stable_0
  %b = load ptr addrspace(1), ptr @oop_handle_Stable_1
  %na = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %nb = call i32 @jeandle.arraylength(ptr addrspace(1) %b)
  %r = call i32 @jeandle.string_compare(ptr addrspace(1) %a, i32 %na, ptr addrspace(1) %b, i32 %nb, i32 0)
  ret i32 %r
}
; CHECK-LABEL: @mutable_compare(
; CHECK-NOT: @jeandle.arraylength
; CHECK-NOT: @jeandle.string_compare
; CHECK: load atomic i8
; CHECK: ret i32
define i32 @mutable_compare() {
  %a = load ptr addrspace(1), ptr @oop_handle_Mutable_2
  %b = load ptr addrspace(1), ptr @oop_handle_Stable_1
  %na = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %nb = call i32 @jeandle.arraylength(ptr addrspace(1) %b)
  %r = call i32 @jeandle.string_compare(ptr addrspace(1) %a, i32 %na, ptr addrspace(1) %b, i32 %nb, i32 0)
  ret i32 %r
}
!java-method-compilation = !{}
