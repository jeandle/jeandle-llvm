; RUN: opt -S -passes='string-intrinsic-specialization,repeated-constant-field-folding' -jeandle-vm-callback-log=%S/Inputs/stable.cblog -verify-each %s | FileCheck %s

; GetConstantField remains the sole authority for folding Java heap contents.
; The callback replay supplies registered stable bytes, refuses mutable bytes,
; and refuses a stable default value that is not yet foldable.
target datalayout = "e-p:64:64-p1:64:64"
@oop_handle_Stable_0 = external global ptr addrspace(1)
@oop_handle_Stable_1 = external global ptr addrspace(1)
@oop_handle_Mutable_2 = external global ptr addrspace(1)
@oop_handle_Default_3 = external global ptr addrspace(1)
declare i32 @jeandle.string_compare(ptr addrspace(1), i32, ptr addrspace(1), i32, i32)
declare i32 @jeandle.string_indexof_char(ptr addrspace(1), i32, i32, i32, i1)

; CHECK-LABEL: @stable_compare(
; CHECK-NOT: load atomic
; CHECK: ret i32 2
 define i32 @stable_compare() gc "hotspotgc" {
 %a = load ptr addrspace(1), ptr @oop_handle_Stable_0
 %b = load ptr addrspace(1), ptr @oop_handle_Stable_1
 %r = call i32 @jeandle.string_compare(ptr addrspace(1) %a, i32 1, ptr addrspace(1) %b, i32 1, i32 1)
 ret i32 %r
}
; CHECK-LABEL: @mutable(
; CHECK: load atomic i8
; CHECK: ret i32
 define i32 @mutable() gc "hotspotgc" {
 %a = load ptr addrspace(1), ptr @oop_handle_Mutable_2
 %r = call i32 @jeandle.string_indexof_char(ptr addrspace(1) %a, i32 1, i32 0, i32 1, i1 false)
 ret i32 %r
}
; CHECK-LABEL: @stable_default(
; CHECK: load atomic i8
; CHECK: ret i32
 define i32 @stable_default() gc "hotspotgc" {
 %a = load ptr addrspace(1), ptr @oop_handle_Default_3
 %r = call i32 @jeandle.string_indexof_char(ptr addrspace(1) %a, i32 0, i32 0, i32 1, i1 false)
 ret i32 %r
}

; CHECK-LABEL: @latin_negative(
; CHECK: ret i32 0
define i32 @latin_negative() gc "hotspotgc" {
 %a = load ptr addrspace(1), ptr @oop_handle_Stable_1
 %r = call i32 @jeandle.string_indexof_char(ptr addrspace(1) %a, i32 -1, i32 0, i32 1, i1 false)
 ret i32 %r
}

; CHECK-LABEL: @latin_truncated(
; CHECK: ret i32 0
define i32 @latin_truncated() gc "hotspotgc" {
 %a = load ptr addrspace(1), ptr @oop_handle_Stable_0
 %r = call i32 @jeandle.string_indexof_char(ptr addrspace(1) %a, i32 257, i32 0, i32 1, i1 false)
 ret i32 %r
}

; CHECK-LABEL: @utf_negative(
; CHECK: ret i32 -1
define i32 @utf_negative() gc "hotspotgc" {
 %a = load ptr addrspace(1), ptr @oop_handle_Stable_0
 %r = call i32 @jeandle.string_indexof_char(ptr addrspace(1) %a, i32 -1, i32 0, i32 1, i1 true)
 ret i32 %r
}

; CHECK-LABEL: @utf_above(
; CHECK: ret i32 -1
define i32 @utf_above() gc "hotspotgc" {
 %a = load ptr addrspace(1), ptr @oop_handle_Stable_0
 %r = call i32 @jeandle.string_indexof_char(ptr addrspace(1) %a, i32 65536, i32 0, i32 1, i1 true)
 ret i32 %r
}



@oop_handle_Chars_4 = external global ptr addrspace(1)
declare i32 @jeandle.string_compress(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)
; The first character is written; the failing second and all later cells
; retain their original contents. Failure returns zero, not prefix length.
; CHECK-LABEL: @stable_compress_failure(
; CHECK-NOT: store
; CHECK: store atomic i8 65
; CHECK-NOT: store
; CHECK: ret i32 0
 define i32 @stable_compress_failure(ptr addrspace(1) %dst) gc "hotspotgc" {
 %a = load ptr addrspace(1), ptr @oop_handle_Chars_4
 %r = call i32 @jeandle.string_compress(ptr addrspace(1) %a, i32 0, ptr addrspace(1) %dst, i32 1, i32 3, i1 false)
 ret i32 %r
}
!java-method-compilation = !{}
