; RUN: opt -S -passes='string-intrinsic-specialization,instcombine,simplifycfg' -verify-each %s | FileCheck %s
; RUN: opt -S -passes='string-intrinsic-specialization,instcombine,simplifycfg,string-intrinsic-specialization,instcombine,simplifycfg' -verify-each %s | FileCheck %s

target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
@arrayOopDesc.base_offset_in_bytes.char = constant i32 16
@oop_handle_stable_1 = external global ptr addrspace(1)
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @jeandle.string_compress(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)
declare void @jeandle.string_inflate(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)
declare void @jeandle.string_copy_utf16(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)

; Without an allocation or a known Java oop source, 9..16 cells cannot
; enable virtual-array elimination or trusted stable-content folding.
; Keep the named operation available for the bounded native kernel.

; CHECK-LABEL: @material_compress_7_false(
; CHECK: load atomic i16
; CHECK-NOT: @jeandle.string_compress
; CHECK: ret i32
define i32 @material_compress_7_false(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %r = call i32 @jeandle.string_compress(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 7, i1 false)
  ret i32 %r
}

; CHECK-LABEL: @material_compress_7_true(
; CHECK: load atomic i8
; CHECK-NOT: @jeandle.string_compress
; CHECK: ret i32
define i32 @material_compress_7_true(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %r = call i32 @jeandle.string_compress(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 7, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @material_compress_8_false(
; CHECK: load atomic i16
; CHECK-NOT: @jeandle.string_compress
; CHECK: ret i32
define i32 @material_compress_8_false(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %r = call i32 @jeandle.string_compress(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 8, i1 false)
  ret i32 %r
}

; CHECK-LABEL: @material_compress_8_true(
; CHECK: load atomic i8
; CHECK-NOT: @jeandle.string_compress
; CHECK: ret i32
define i32 @material_compress_8_true(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %r = call i32 @jeandle.string_compress(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 8, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @material_compress_9_false(
; CHECK: call i32 @jeandle.string_compress
; CHECK: ret i32
define i32 @material_compress_9_false(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %r = call i32 @jeandle.string_compress(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 9, i1 false)
  ret i32 %r
}

; CHECK-LABEL: @material_compress_9_true(
; CHECK: call i32 @jeandle.string_compress
; CHECK: ret i32
define i32 @material_compress_9_true(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %r = call i32 @jeandle.string_compress(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 9, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @material_compress_16_false(
; CHECK: call i32 @jeandle.string_compress
; CHECK: ret i32
define i32 @material_compress_16_false(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %r = call i32 @jeandle.string_compress(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 16, i1 false)
  ret i32 %r
}

; CHECK-LABEL: @material_compress_16_true(
; CHECK: call i32 @jeandle.string_compress
; CHECK: ret i32
define i32 @material_compress_16_true(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %r = call i32 @jeandle.string_compress(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 16, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @material_compress_17_false(
; CHECK: call i32 @jeandle.string_compress
; CHECK: ret i32
define i32 @material_compress_17_false(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %r = call i32 @jeandle.string_compress(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 17, i1 false)
  ret i32 %r
}

; CHECK-LABEL: @material_compress_17_true(
; CHECK: call i32 @jeandle.string_compress
; CHECK: ret i32
define i32 @material_compress_17_true(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %r = call i32 @jeandle.string_compress(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 17, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @allocation_compress_9(
; CHECK: load atomic i8
; CHECK-NOT: @jeandle.string_compress
; CHECK: ret i32
define i32 @allocation_compress_9(ptr addrspace(1) %arg, ptr addrspace(1) %dst) {
  %src = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 40, i32 64, i32 16, i32 100, i1 false, i1 false)
  %r = call i32 @jeandle.string_compress(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 9, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @allocation_compress_16(
; CHECK: load atomic i8
; CHECK-NOT: @jeandle.string_compress
; CHECK: ret i32
define i32 @allocation_compress_16(ptr addrspace(1) %arg, ptr addrspace(1) %dst) {
  %src = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 40, i32 64, i32 16, i32 100, i1 false, i1 false)
  %r = call i32 @jeandle.string_compress(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 16, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @stable_compress_9(
; CHECK: load atomic i8
; CHECK-NOT: @jeandle.string_compress
; CHECK: ret i32
define i32 @stable_compress_9(ptr addrspace(1) %arg, ptr addrspace(1) %dst) {
  %src = load ptr addrspace(1), ptr @oop_handle_stable_1
  %r = call i32 @jeandle.string_compress(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 9, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @stable_compress_16(
; CHECK: load atomic i8
; CHECK-NOT: @jeandle.string_compress
; CHECK: ret i32
define i32 @stable_compress_16(ptr addrspace(1) %arg, ptr addrspace(1) %dst) {
  %src = load ptr addrspace(1), ptr @oop_handle_stable_1
  %r = call i32 @jeandle.string_compress(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 16, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @material_inflate_7_false(
; CHECK: load atomic i8
; CHECK-NOT: @jeandle.string_inflate
; CHECK: ret void
define void @material_inflate_7_false(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  call void @jeandle.string_inflate(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 7, i1 false)
  ret void
}

; CHECK-LABEL: @material_inflate_7_true(
; CHECK: load atomic i8
; CHECK-NOT: @jeandle.string_inflate
; CHECK: ret void
define void @material_inflate_7_true(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  call void @jeandle.string_inflate(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 7, i1 true)
  ret void
}

; CHECK-LABEL: @material_inflate_8_false(
; CHECK: load atomic i8
; CHECK-NOT: @jeandle.string_inflate
; CHECK: ret void
define void @material_inflate_8_false(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  call void @jeandle.string_inflate(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 8, i1 false)
  ret void
}

; CHECK-LABEL: @material_inflate_8_true(
; CHECK: load atomic i8
; CHECK-NOT: @jeandle.string_inflate
; CHECK: ret void
define void @material_inflate_8_true(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  call void @jeandle.string_inflate(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 8, i1 true)
  ret void
}

; CHECK-LABEL: @material_inflate_9_false(
; CHECK: call void @jeandle.string_inflate
; CHECK: ret void
define void @material_inflate_9_false(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  call void @jeandle.string_inflate(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 9, i1 false)
  ret void
}

; CHECK-LABEL: @material_inflate_9_true(
; CHECK: call void @jeandle.string_inflate
; CHECK: ret void
define void @material_inflate_9_true(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  call void @jeandle.string_inflate(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 9, i1 true)
  ret void
}

; CHECK-LABEL: @material_inflate_16_false(
; CHECK: call void @jeandle.string_inflate
; CHECK: ret void
define void @material_inflate_16_false(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  call void @jeandle.string_inflate(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 16, i1 false)
  ret void
}

; CHECK-LABEL: @material_inflate_16_true(
; CHECK: call void @jeandle.string_inflate
; CHECK: ret void
define void @material_inflate_16_true(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  call void @jeandle.string_inflate(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 16, i1 true)
  ret void
}

; CHECK-LABEL: @material_inflate_17_false(
; CHECK: call void @jeandle.string_inflate
; CHECK: ret void
define void @material_inflate_17_false(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  call void @jeandle.string_inflate(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 17, i1 false)
  ret void
}

; CHECK-LABEL: @material_inflate_17_true(
; CHECK: call void @jeandle.string_inflate
; CHECK: ret void
define void @material_inflate_17_true(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  call void @jeandle.string_inflate(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 17, i1 true)
  ret void
}

; CHECK-LABEL: @allocation_inflate_9(
; CHECK: load atomic i8
; CHECK-NOT: @jeandle.string_inflate
; CHECK: ret void
define void @allocation_inflate_9(ptr addrspace(1) %arg, ptr addrspace(1) %dst) {
  %src = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 40, i32 64, i32 16, i32 100, i1 false, i1 false)
  call void @jeandle.string_inflate(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 9, i1 true)
  ret void
}

; CHECK-LABEL: @allocation_inflate_16(
; CHECK: load atomic i8
; CHECK-NOT: @jeandle.string_inflate
; CHECK: ret void
define void @allocation_inflate_16(ptr addrspace(1) %arg, ptr addrspace(1) %dst) {
  %src = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 40, i32 64, i32 16, i32 100, i1 false, i1 false)
  call void @jeandle.string_inflate(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 16, i1 true)
  ret void
}

; CHECK-LABEL: @stable_inflate_9(
; CHECK: load atomic i8
; CHECK-NOT: @jeandle.string_inflate
; CHECK: ret void
define void @stable_inflate_9(ptr addrspace(1) %arg, ptr addrspace(1) %dst) {
  %src = load ptr addrspace(1), ptr @oop_handle_stable_1
  call void @jeandle.string_inflate(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 9, i1 true)
  ret void
}

; CHECK-LABEL: @stable_inflate_16(
; CHECK: load atomic i8
; CHECK-NOT: @jeandle.string_inflate
; CHECK: ret void
define void @stable_inflate_16(ptr addrspace(1) %arg, ptr addrspace(1) %dst) {
  %src = load ptr addrspace(1), ptr @oop_handle_stable_1
  call void @jeandle.string_inflate(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 16, i1 true)
  ret void
}

; UTF16 copies retain their atomic cell policy.
; CHECK-LABEL: @copy16(
; CHECK: load atomic i16
; CHECK-NOT: @jeandle.string_copy_utf16
; CHECK: ret void
define void @copy16(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  call void @jeandle.string_copy_utf16(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 16, i1 false)
  ret void
}
