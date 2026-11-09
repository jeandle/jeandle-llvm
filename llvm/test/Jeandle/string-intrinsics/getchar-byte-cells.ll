; RUN: opt -S -passes='string-intrinsic-specialization,partial-escape-iterative,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/Inputs/getchar-byte-cells.cblog -verify-each %s | FileCheck %s --check-prefixes=CHECK,LE
; RUN: sed 's/target datalayout = "e-/target datalayout = "E-/' %s | opt -S -passes='string-intrinsic-specialization,partial-escape-iterative,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/Inputs/getchar-byte-cells.cblog -verify-each | FileCheck %s --check-prefixes=CHECK,BE
target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
@arrayOopDesc.base_offset_in_bytes.char = constant i32 16
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.string_copy_utf16(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)
declare hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1), i32) nounwind memory(read)
declare void @escape(ptr addrspace(1))
declare hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)
!java-method-compilation = !{}

; CHECK-LABEL: @bytes(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.string_getchar
; CHECK-DAG: zext i8 %lo to i16
; CHECK-DAG: zext i8 %hi to i16
; CHECK: ret i16
define i16 @bytes(i8 %lo, i8 %hi) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %p = getelementptr i8, ptr addrspace(1) %a, i64 16
 %q = getelementptr i8, ptr addrspace(1) %a, i64 17
 store atomic i8 %lo, ptr addrspace(1) %p unordered, align 1
 store atomic i8 %hi, ptr addrspace(1) %q unordered, align 1
 %r = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 0)
 ret i16 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @default_high(
; CHECK-NOT: @jeandle.new_array
; LE: ret i16 18
; BE: ret i16 4608
define i16 @default_high(i8 %lo, i8 %hi) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %p = getelementptr i8, ptr addrspace(1) %a, i64 16
 %q = getelementptr i8, ptr addrspace(1) %a, i64 17
 store atomic i8 18, ptr addrspace(1) %p unordered, align 1
 %r = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 0)
 ret i16 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @overwrite(
; CHECK-NOT: @jeandle.new_array
; LE: ret i16 -23278
; BE: ret i16 4773
define i16 @overwrite(i8 %lo, i8 %hi) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %p = getelementptr i8, ptr addrspace(1) %a, i64 16
 %q = getelementptr i8, ptr addrspace(1) %a, i64 17
 store atomic i8 1, ptr addrspace(1) %p unordered, align 1
 store atomic i8 18, ptr addrspace(1) %p unordered, align 1
 store atomic i8 -91, ptr addrspace(1) %q unordered, align 1
 %r = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 0)
 ret i16 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @later_escape(
; CHECK: @jeandle.new_array
; CHECK: store atomic i8 %lo
; CHECK: store atomic i8 %hi
; CHECK-NOT: @jeandle.string_getchar
; CHECK: call void @escape
; CHECK: ret i16
define i16 @later_escape(i8 %lo, i8 %hi) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %p = getelementptr i8, ptr addrspace(1) %a, i64 16
 %q = getelementptr i8, ptr addrspace(1) %a, i64 17
 store atomic i8 %lo, ptr addrspace(1) %p unordered, align 1
 store atomic i8 %hi, ptr addrspace(1) %q unordered, align 1
 %r = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 0)
 call void @escape(ptr addrspace(1) %a)
 ret i16 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @material_first(
; CHECK: @jeandle.new_array
; CHECK: call void @escape
; CHECK: call hotspotcc i16 @jeandle.string_getchar
define i16 @material_first(i8 %lo, i8 %hi) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %p = getelementptr i8, ptr addrspace(1) %a, i64 16
 %q = getelementptr i8, ptr addrspace(1) %a, i64 17
 store atomic i8 %lo, ptr addrspace(1) %p unordered, align 1
 call void @escape(ptr addrspace(1) %a)
 %r = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 0)
 ret i16 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @roundtrip(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.string_getchar
; CHECK: ret i16 %character
define i16 @roundtrip(i16 %character) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 1, i32 24, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 true, i1 true) to label %work unwind label %u
work:
 %sp = getelementptr i8, ptr addrspace(1) %src, i64 16
 store atomic i16 %character, ptr addrspace(1) %sp unordered, align 2
 call void @jeandle.string_copy_utf16(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 1, i1 false)
 %result = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %dst, i32 0)
 ret i16 %result
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; A later raw word access materializes the byte layout. Both byte values
; must be replayed before the surviving material read.
; CHECK-LABEL: @word_materialization(
; CHECK: @jeandle.new_array
; CHECK: store atomic i8 %lo
; CHECK: store atomic i8 %hi
; CHECK-NOT: call hotspotcc i16 @jeandle.string_getchar
; CHECK: load atomic i16
; CHECK: ret i16
define i16 @word_materialization(i8 %lo, i8 %hi) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %p = getelementptr i8, ptr addrspace(1) %a, i64 16
 %q = getelementptr i8, ptr addrspace(1) %a, i64 17
 store atomic i8 %lo, ptr addrspace(1) %p unordered, align 1
 store atomic i8 %hi, ptr addrspace(1) %q unordered, align 1
 %r = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 0)
 %raw = load atomic i16, ptr addrspace(1) %p unordered, align 2
 %answer = xor i16 %r, %raw
 ret i16 %answer
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; The synthetic callback marks this klass value-based to exercise late
; eligibility cancellation. getChar's byte definition must survive an overwrite.
; CHECK-LABEL: @late_eligibility_cancellation(
; CHECK: @jeandle.new_array
; CHECK: store atomic i8 %lo
; CHECK: store atomic i8 %hi
; CHECK: %r = call hotspotcc i16 @jeandle.string_getchar
; CHECK: store atomic i8 %later
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based
; CHECK: ret i16 %r
define i16 @late_eligibility_cancellation(i8 %lo, i8 %hi, i8 %later) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %p = getelementptr i8, ptr addrspace(1) %a, i64 16
 %q = getelementptr i8, ptr addrspace(1) %a, i64 17
 store atomic i8 %lo, ptr addrspace(1) %p unordered, align 1
 store atomic i8 %hi, ptr addrspace(1) %q unordered, align 1
 %r = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 0)
 store atomic i8 %later, ptr addrspace(1) %q unordered, align 1
 %vb = call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %a)
 ret i16 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}
