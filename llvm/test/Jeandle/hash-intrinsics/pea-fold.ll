; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/Inputs/layout.cblog -verify-each %s | FileCheck %s

; Positive folds of jeandle.vectorizedHashCode over virtual arrays with
; constant, in-range lengths. Constant cells fold to a constant result,
; a length of zero replaces the call with the initial value itself, and
; scalar cells lower to a placed Horner chain. Klass ids: 10001 byte[],
; 10002 char[], 10003 short[], 10004 int[].

target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
@arrayOopDesc.base_offset_in_bytes.char = constant i32 16
@arrayOopDesc.base_offset_in_bytes.short = constant i32 16
@arrayOopDesc.base_offset_in_bytes.int = constant i32 16
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @jeandle.vectorized_hashcode(ptr addrspace(1), i32, i32, i32, i32)
declare i32 @__gxx_personality_v0(...)

; CHECK-LABEL: @bytes_const(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: ret i32 152
define i32 @bytes_const() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 17
  store atomic i8 5, ptr addrspace(1) %p0 unordered, align 1
  store atomic i8 -3, ptr addrspace(1) %p1 unordered, align 1
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 2, i32 0, i32 8)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; T_BOOLEAN reads the same byte[] payload as unsigned lanes.
; CHECK-LABEL: @boolean_const(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: ret i32 1367
define i32 @boolean_const() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 17
  store atomic i8 5, ptr addrspace(1) %p0 unordered, align 1
  store atomic i8 -5, ptr addrspace(1) %p1 unordered, align 1
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 2, i32 1, i32 4)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; char[] cells widen zero-extended.
; CHECK-LABEL: @chars_const(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: ret i32 40735
define i32 @chars_const() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 18
  store atomic i16 257, ptr addrspace(1) %p0 unordered, align 2
  store atomic i16 -32768, ptr addrspace(1) %p1 unordered, align 2
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 2, i32 0, i32 5)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; short[] cells widen sign-extended.
; CHECK-LABEL: @shorts_const(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: ret i32 1016736
define i32 @shorts_const() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10003 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 18
  store atomic i16 32767, ptr addrspace(1) %p0 unordered, align 2
  store atomic i16 -2, ptr addrspace(1) %p1 unordered, align 2
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 2, i32 1, i32 9)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; int[] cells hash without widening.
; CHECK-LABEL: @ints_const(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: ret i32 683130222
define i32 @ints_const() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 20
  store atomic i32 -1640531527, ptr addrspace(1) %p0 unordered, align 4
  store atomic i32 7, ptr addrspace(1) %p1 unordered, align 4
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 2, i32 0, i32 10)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; T_CHAR over a byte[] payload composes native-endian pairs (little-endian
; host: low byte first).
; CHECK-LABEL: @utf16_const(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: ret i32 1367
define i32 @utf16_const() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 17
  %p2 = getelementptr i8, ptr addrspace(1) %a, i64 18
  %p3 = getelementptr i8, ptr addrspace(1) %a, i64 19
  store atomic i8 5, ptr addrspace(1) %p0 unordered, align 1
  store atomic i8 0, ptr addrspace(1) %p1 unordered, align 1
  store atomic i8 -5, ptr addrspace(1) %p2 unordered, align 1
  store atomic i8 0, ptr addrspace(1) %p3 unordered, align 1
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 2, i32 1, i32 5)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Never-stored cells read the Java default zero.
; CHECK-LABEL: @default_cells(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: ret i32 0
define i32 @default_cells() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 3, i32 0, i32 4)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A zero length replaces the call with the initial value operand itself,
; constant or not.
; CHECK-LABEL: @zero_length(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: ret i32 %init
define i32 @zero_length(i32 %init) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 0, i32 %init, i32 10)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Scalar cells lower to a placed sign-extension Horner chain; the allocation
; and the op both disappear.
; CHECK-LABEL: @scalar_chain(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: sext i8 %v to i32
; CHECK: mul i32
; CHECK: mul i32
; CHECK: ret i32
define i32 @scalar_chain(i8 %v, i32 %init) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 17
  store atomic i8 %v, ptr addrspace(1) %p0 unordered, align 1
  store atomic i8 9, ptr addrspace(1) %p1 unordered, align 1
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 2, i32 %init, i32 8)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}
