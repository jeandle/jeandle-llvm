; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/Inputs/layout.cblog -verify-each %s | FileCheck %s

; A tightly coupled initializer allocates the copy destination with the
; extended seven-operand jeandle.new_array signature (trailing i1
; uninitialized / deferred-publication flags). The extra operands must not
; stop length extraction: the allocation still virtualizes, the copy still
; folds against it, and both allocations disappear when nothing escapes.

target datalayout = "e-p:64:64-p1:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @__gxx_personality_v0(...)
declare void @jeandle.string_copy_utf16(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)

; CHECK-LABEL: @uninitialized_copy_folds(
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: call
; CHECK: ret i32 18
define i32 @uninitialized_copy_folds() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 true, i1 true) to label %work unwind label %u
work:
 %ap = getelementptr i8, ptr addrspace(1) %a, i64 16
 store atomic i16 4660, ptr addrspace(1) %ap unordered, align 2
 call void @jeandle.string_copy_utf16(ptr addrspace(1) %a, i32 0, ptr addrspace(1) %b, i32 0, i32 1, i1 false)
 %bp = getelementptr i8, ptr addrspace(1) %b, i64 17
 %v = load atomic i8, ptr addrspace(1) %bp unordered, align 1
 %r = zext i8 %v to i32
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; The same extended-signature allocation that escapes by returning it must
; stay a recognized allocation site and materialize, never be dropped as an
; opaque call.
; CHECK-LABEL: @uninitialized_escapes(
; CHECK: jeandle.new_array
; CHECK: ret ptr addrspace(1)
define ptr addrspace(1) @uninitialized_escapes() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 true, i1 true) to label %next unwind label %u
next:
 ret ptr addrspace(1) %b
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

!java-method-compilation = !{}
