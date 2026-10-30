; RUN: opt -S -passes='string-intrinsic-specialization' -verify-each %s | FileCheck %s
; Near names, varargs, wrong return/argument types, wrong address spaces,
; nonconstant/invalid encoding and operand bundles are not the string ABI.
declare i64 @jeandle.string_equals(ptr addrspace(1), ptr addrspace(1), i32)
declare i32 @jeandle.string_compare(ptr, i32, ptr, i32, i32)
declare i32 @jeandle.string_indexof(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i32)
declare i32 @jeandle.string_indexof_char(ptr addrspace(1), i32, i32, i32, i1)
declare void @jeandle.string_copy_utf16(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i32)
declare i32 @jeandle.string_compress(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1, ...)
declare void @jeandle.string_inflate(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)
declare i32 @jeandle.string_equals.extra(ptr addrspace(1), ptr addrspace(1), i32)
; CHECK-LABEL: @invalid(
; CHECK: call i64 @jeandle.string_equals
; CHECK: call i32 @jeandle.string_compare
; CHECK: call i32 @jeandle.string_indexof
; CHECK: call i32 @jeandle.string_indexof
; CHECK: call i32 @jeandle.string_indexof_char
; CHECK: call void @jeandle.string_copy_utf16
; CHECK: call i32 {{.*}}@jeandle.string_compress
; CHECK: call void @jeandle.string_inflate
; CHECK: call i32 @jeandle.string_equals.extra
 define void @invalid(ptr addrspace(1) %a, ptr addrspace(1) %b, ptr %p, i32 %e, i1 %u) {
 %x = call i64 @jeandle.string_equals(ptr addrspace(1) %a, ptr addrspace(1) %a, i32 1)
 %c = call i32 @jeandle.string_compare(ptr %p, i32 1, ptr %p, i32 1, i32 0)
 %i = call i32 @jeandle.string_indexof(ptr addrspace(1) %a, i32 1, ptr addrspace(1) %b, i32 1, i32 0, i32 4)
 %j = call i32 @jeandle.string_indexof(ptr addrspace(1) %a, i32 1, ptr addrspace(1) %b, i32 1, i32 0, i32 %e)
 %k = call i32 @jeandle.string_indexof_char(ptr addrspace(1) %a, i32 1, i32 0, i32 1, i1 %u)
 call void @jeandle.string_copy_utf16(ptr addrspace(1) %a, i32 0, ptr addrspace(1) %b, i32 0, i32 1, i32 1)
 %v = call i32 (ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1, ...) @jeandle.string_compress(ptr addrspace(1) %a, i32 0, ptr addrspace(1) %b, i32 0, i32 1, i1 false)
 call void @jeandle.string_inflate(ptr addrspace(1) %a, i32 0, ptr addrspace(1) %b, i32 0, i32 1, i1 true) [ "deopt"(i32 1) ]
 %z = call i32 @jeandle.string_equals.extra(ptr addrspace(1) %a, ptr addrspace(1) %a, i32 1)
 ret void
}
