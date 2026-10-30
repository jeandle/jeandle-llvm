; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/Inputs/layout.cblog -verify-each %s | FileCheck %s

target datalayout = "e-p:64:64-p1:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @__gxx_personality_v0(...)
declare i32 @jeandle.string_compare(ptr addrspace(1), i32, ptr addrspace(1), i32, i32)
declare i32 @jeandle.string_equals(ptr addrspace(1), ptr addrspace(1), i32)
declare i32 @jeandle.string_indexof(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i32)
declare i32 @jeandle.string_indexof_char(ptr addrspace(1), i32, i32, i32, i1)
declare i32 @jeandle.string_compress(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)
declare void @jeandle.string_inflate(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)
declare void @jeandle.string_copy_utf16(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)

; CHECK-LABEL: @known_compare(
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: call
; CHECK: ret i32 255
define i32 @known_compare() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %ap = getelementptr i8, ptr addrspace(1) %a, i64 16
 store atomic i8 -1, ptr addrspace(1) %ap unordered, align 1
 %r = call i32 @jeandle.string_compare(ptr addrspace(1) %a, i32 1, ptr addrspace(1) %b, i32 1, i32 0)
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @known_search(
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: call
; CHECK: ret i32 1
define i32 @known_search() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %r = call i32 @jeandle.string_indexof(ptr addrspace(1) %a, i32 4, ptr addrspace(1) %b, i32 2, i32 1, i32 0)
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @known_char(
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: call
; CHECK: ret i32 -1
define i32 @known_char() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %r = call i32 @jeandle.string_indexof_char(ptr addrspace(1) %a, i32 256, i32 0, i32 2, i1 true)
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @known_equals(
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: call
; CHECK: ret i32 1
define i32 @known_equals() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %r = call i32 @jeandle.string_equals(ptr addrspace(1) %a, ptr addrspace(1) %b, i32 4)
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @compress_prefix(
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: call
; CHECK: ret i32 72
define i32 @compress_prefix() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %ap = getelementptr i8, ptr addrspace(1) %a, i64 16
 %ap1 = getelementptr i8, ptr addrspace(1) %a, i64 18
 store atomic i16 65, ptr addrspace(1) %ap unordered, align 2
 store atomic i16 256, ptr addrspace(1) %ap1 unordered, align 2
 %bp1 = getelementptr i8, ptr addrspace(1) %b, i64 17
 store atomic i8 7, ptr addrspace(1) %bp1 unordered, align 1
 %r = call i32 @jeandle.string_compress(ptr addrspace(1) %a, i32 0, ptr addrspace(1) %b, i32 0, i32 3, i1 false)
 %bp = getelementptr i8, ptr addrspace(1) %b, i64 16
 %first = load atomic i8, ptr addrspace(1) %bp unordered, align 1
 %sentinel = load atomic i8, ptr addrspace(1) %bp1 unordered, align 1
 %x = zext i8 %first to i32
 %y = zext i8 %sentinel to i32
 %z = add i32 %x, %y
 %answer = add i32 %z, %r
 ret i32 %answer
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @inflate_char(
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: call
; CHECK: ret i32 255
define i32 @inflate_char() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %ap = getelementptr i8, ptr addrspace(1) %a, i64 16
 store atomic i8 -1, ptr addrspace(1) %ap unordered, align 1
 call void @jeandle.string_inflate(ptr addrspace(1) %a, i32 0, ptr addrspace(1) %b, i32 0, i32 1, i1 false)
 %bp = getelementptr i8, ptr addrspace(1) %b, i64 16
 %v = load atomic i16, ptr addrspace(1) %bp unordered, align 2
 %r = zext i16 %v to i32
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @copy_native(
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: call
; CHECK: ret i32 18
define i32 @copy_native() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
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



; CHECK-LABEL: @latin_256(
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: call
; CHECK: ret i32 0
define i32 @latin_256() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %p = getelementptr i8, ptr addrspace(1) %a, i64 16
 store atomic i8 0, ptr addrspace(1) %p unordered, align 1
 %r = call i32 @jeandle.string_indexof_char(ptr addrspace(1) %a, i32 256, i32 0, i32 1, i1 false)
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @latin_minus1(
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: call
; CHECK: ret i32 0
define i32 @latin_minus1() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %p = getelementptr i8, ptr addrspace(1) %a, i64 16
 store atomic i8 255, ptr addrspace(1) %p unordered, align 1
 %r = call i32 @jeandle.string_indexof_char(ptr addrspace(1) %a, i32 -1, i32 0, i32 1, i1 false)
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @utf_minus1(
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: call
; CHECK: ret i32 -1
define i32 @utf_minus1() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %p = getelementptr i8, ptr addrspace(1) %a, i64 16
 store atomic i8 0, ptr addrspace(1) %p unordered, align 1
 %r = call i32 @jeandle.string_indexof_char(ptr addrspace(1) %a, i32 -1, i32 0, i32 1, i1 true)
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @utf_65536(
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: call
; CHECK: ret i32 -1
define i32 @utf_65536() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %p = getelementptr i8, ptr addrspace(1) %a, i64 16
 store atomic i8 0, ptr addrspace(1) %p unordered, align 1
 %r = call i32 @jeandle.string_indexof_char(ptr addrspace(1) %a, i32 65536, i32 0, i32 1, i1 true)
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

!java-method-compilation = !{}
