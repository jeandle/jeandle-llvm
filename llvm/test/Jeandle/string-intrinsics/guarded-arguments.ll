; RUN: opt -S -passes='string-intrinsic-specialization,instcombine,simplifycfg' -verify-each %s | FileCheck %s

target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
@arrayOopDesc.base_offset_in_bytes.char = constant i32 16
declare void @jeandle.string_inflate(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)
declare i32 @jeandle.string_equals(ptr addrspace(1), ptr addrspace(1), i32)
declare i32 @jeandle.arraylength(ptr addrspace(1))
declare void @may_write()

; Array lengths are immutable across intervening calls. A String count can
; reuse a dominating guard without treating mutable array contents as stable.
; CHECK-LABEL: @reloaded_guarded_length(
; CHECK: call void @may_write
; CHECK: load atomic i8
; CHECK-NOT: call i32 @jeandle.string_equals
; CHECK: ret i32
define i32 @reloaded_guarded_length(ptr addrspace(1) %a, ptr addrspace(1) %b) {
entry:
  %old = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %valid = icmp eq i32 %old, 1
  br i1 %valid, label %work, label %exit
work:
  call void @may_write()
  %new = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %r = call i32 @jeandle.string_equals(ptr addrspace(1) %a, ptr addrspace(1) %b, i32 %new)
  ret i32 %r
exit:
  ret i32 -1
}

; A guard on another array cannot bound this count.
; CHECK-LABEL: @different_array_length(
; CHECK: call i32 @jeandle.string_equals
define i32 @different_array_length(ptr addrspace(1) %a, ptr addrspace(1) %b) {
entry:
  %old = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %valid = icmp eq i32 %old, 1
  br i1 %valid, label %work, label %exit
work:
  %new = call i32 @jeandle.arraylength(ptr addrspace(1) %b)
  %r = call i32 @jeandle.string_equals(ptr addrspace(1) %a, ptr addrspace(1) %b, i32 %new)
  ret i32 %r
exit:
  ret i32 -1
}

; A dominating Java guard proves the length without rewriting the SSA value.
; CHECK-LABEL: @guarded_inflate(
; CHECK: store atomic i16
; CHECK-NOT: @jeandle.string_inflate
; CHECK: ret void
define void @guarded_inflate(ptr addrspace(1) %src, ptr addrspace(1) %dst, i32 %n) {
entry:
  %valid = icmp eq i32 %n, 8
  br i1 %valid, label %work, label %exit
work:
  call void @jeandle.string_inflate(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 %n, i1 false)
  br label %exit
exit:
  ret void
}

; Plan analysis for both calls before expanding either one's CFG.
; CHECK-LABEL: @two_guarded_calls(
; CHECK: load atomic i8
; CHECK: store atomic i16
; CHECK-NOT: @jeandle.string_equals
; CHECK-NOT: @jeandle.string_inflate
; CHECK: ret i32
define i32 @two_guarded_calls(ptr addrspace(1) %src, ptr addrspace(1) %other, ptr addrspace(1) %dst, i32 %n) {
entry:
  %valid = icmp eq i32 %n, 4
  br i1 %valid, label %work, label %exit
work:
  %r = call i32 @jeandle.string_equals(ptr addrspace(1) %src, ptr addrspace(1) %other, i32 %n)
  call void @jeandle.string_inflate(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 %n, i1 false)
  ret i32 %r
exit:
  ret i32 -1
}

; A range with multiple values is not a constant-length unrolling contract.
; CHECK-LABEL: @bounded_dynamic(
; CHECK: call void @jeandle.string_inflate{{.*}}i32 %n
; CHECK: ret void
define void @bounded_dynamic(ptr addrspace(1) %src, ptr addrspace(1) %dst, i32 %n) {
entry:
  %valid = icmp ult i32 %n, 8
  br i1 %valid, label %work, label %exit
work:
  call void @jeandle.string_inflate(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 %n, i1 false)
  br label %exit
exit:
  ret void
}
