; RUN: opt -S -passes='string-intrinsic-specialization,instcombine,simplifycfg' -verify-each %s | FileCheck %s

target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 24
@arrayOopDesc.base_offset_in_bytes.char = constant i32 32

declare i32 @jeandle.string_equals(ptr addrspace(1), ptr addrspace(1), i32)
declare i32 @jeandle.string_compare(ptr addrspace(1), i32, ptr addrspace(1), i32, i32)
declare i32 @jeandle.string_indexof(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i32)
declare i32 @jeandle.string_indexof_char(ptr addrspace(1), i32, i32, i32, i1)
declare void @jeandle.string_copy_utf16(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)
declare i32 @jeandle.string_compress(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)
declare void @jeandle.string_inflate(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)

; CHECK-LABEL: @identity(
; CHECK-NOT: call
; CHECK: sub i32 %n, %m
; CHECK: ret i32
 define i32 @identity(ptr addrspace(1) %a, i32 %n, i32 %m) {
 %r = call i32 @jeandle.string_compare(ptr addrspace(1) %a, i32 %n, ptr addrspace(1) %a, i32 %m, i32 3)
 ret i32 %r
}

; CHECK-LABEL: @mixed_identity(
; CHECK: call i32 @jeandle.string_compare
 define i32 @mixed_identity(ptr addrspace(1) %a, i32 %n) {
 %r = call i32 @jeandle.string_compare(ptr addrspace(1) %a, i32 %n, ptr addrspace(1) %a, i32 %n, i32 1)
 ret i32 %r
}

; CHECK-LABEL: @compare_one(
; CHECK: getelementptr i8, ptr addrspace(1) %a, i64 24
; CHECK: load atomic i8, {{.*}} unordered, align 1
; CHECK: zext i8
; CHECK: load atomic i8
; CHECK: zext i8
; CHECK: shl
; CHECK: or
; CHECK: load atomic i8
; CHECK: zext i8
; CHECK: sub
; CHECK-NOT: call
; CHECK: ret i32
 define i32 @compare_one(ptr addrspace(1) %a, ptr addrspace(1) %b) {
 %r = call i32 @jeandle.string_compare(ptr addrspace(1) %a, i32 1, ptr addrspace(1) %b, i32 1, i32 1)
 ret i32 %r
}

; CHECK-LABEL: @find_char(
; CHECK: load atomic i8
; CHECK: icmp eq i32
; CHECK-NOT: call
; CHECK: ret i32
 define i32 @find_char(ptr addrspace(1) %a, i32 %ch) {
 %r = call i32 @jeandle.string_indexof_char(ptr addrspace(1) %a, i32 %ch, i32 3, i32 5, i1 true)
 ret i32 %r
}

; CHECK-LABEL: @substring(
; CHECK: load atomic i8
; CHECK: load atomic i8
; CHECK-NOT: call
; CHECK: ret i32
 define i32 @substring(ptr addrspace(1) %a, ptr addrspace(1) %b) {
 %r = call i32 @jeandle.string_indexof(ptr addrspace(1) %a, i32 4, ptr addrspace(1) %b, i32 2, i32 1, i32 1)
 ret i32 %r
}

; CHECK-LABEL: @copy(
; CHECK: getelementptr i8, ptr addrspace(1) %a, i64 34
; CHECK: load atomic i16
; CHECK: getelementptr i8, ptr addrspace(1) %b, i64 28
; CHECK: store atomic i8
; CHECK-NOT: call
; CHECK: ret void
 define void @copy(ptr addrspace(1) %a, ptr addrspace(1) %b) {
 call void @jeandle.string_copy_utf16(ptr addrspace(1) %a, i32 1, ptr addrspace(1) %b, i32 2, i32 2, i1 false)
 ret void
}

; CHECK-LABEL: @compress_prefix(
; CHECK: load atomic i16
; CHECK: icmp ugt i16 {{.*}}, 255
; CHECK: br i1
; CHECK: store atomic i8
; CHECK: load atomic i16
; CHECK: br i1
; CHECK: store atomic i8
; CHECK-NOT: call
; CHECK: ret i32
 define i32 @compress_prefix(ptr addrspace(1) %a, ptr addrspace(1) %b) {
 %r = call i32 @jeandle.string_compress(ptr addrspace(1) %a, i32 0, ptr addrspace(1) %b, i32 0, i32 2, i1 false)
 ret i32 %r
}

; CHECK-LABEL: @inflate(
; CHECK: load atomic i8
; CHECK: store atomic i8
; CHECK: store atomic i8
; CHECK-NOT: call
; CHECK: ret void
 define void @inflate(ptr addrspace(1) %a, ptr addrspace(1) %b) {
 call void @jeandle.string_inflate(ptr addrspace(1) %a, i32 0, ptr addrspace(1) %b, i32 0, i32 1, i1 true)
 ret void
}

; CHECK-LABEL: @dynamic(
; CHECK: call i32 @jeandle.string_equals
 define i32 @dynamic(ptr addrspace(1) %a, ptr addrspace(1) %b, i32 %n) {
 %r = call i32 @jeandle.string_equals(ptr addrspace(1) %a, ptr addrspace(1) %b, i32 %n)
 ret i32 %r
}

; CHECK-LABEL: @over_budget(
; CHECK: call i32 @jeandle.string_indexof
 define i32 @over_budget(ptr addrspace(1) %a, ptr addrspace(1) %b) {
 %r = call i32 @jeandle.string_indexof(ptr addrspace(1) %a, i32 16, ptr addrspace(1) %b, i32 8, i32 0, i32 0)
 ret i32 %r
}

; Successful expansion removes only the leaf op's unwind edge and repairs
; the landingpad predecessor list; the normal result still merges correctly.
declare i32 @personality(...)
declare void @caught()
; CHECK-LABEL: @invoke_compare(
; CHECK-NOT: invoke
; CHECK: load atomic i8
; CHECK-NOT: @caught
; CHECK: ret i32
 define i32 @invoke_compare(ptr addrspace(1) %a, ptr addrspace(1) %b) personality ptr @personality {
entry:
 %r = invoke i32 @jeandle.string_compare(ptr addrspace(1) %a, i32 1, ptr addrspace(1) %b, i32 1, i32 0) to label %normal unwind label %unwind
normal:
 ret i32 %r
unwind:
 %lp = landingpad i64 cleanup
 call void @caught()
 resume i64 %lp
}
