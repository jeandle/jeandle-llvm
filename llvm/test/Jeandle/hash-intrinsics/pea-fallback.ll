; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/Inputs/layout.cblog -verify-each %s | FileCheck %s

; Negative shapes keep the original op and materialize the virtual array:
; non-constant lengths, out-of-range ranges, unreadable cells,
; non-virtual receivers, and utf16 payloads with non-constant bytes.

target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
@arrayOopDesc.base_offset_in_bytes.int = constant i32 16
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @jeandle.vectorized_hashcode(ptr addrspace(1), i32, i32, i32, i32)
declare i32 @__gxx_personality_v0(...)

; CHECK-LABEL: @nonconstant_length(
; CHECK: @jeandle.new_array
; CHECK: call i32 @jeandle.vectorized_hashcode
; CHECK-NOT: poison
; CHECK: ret i32
define i32 @nonconstant_length(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i8 7, ptr addrspace(1) %p0 unordered, align 1
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 %n, i32 0, i32 8)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A segment of default cells has no dynamic scalar cost.
; CHECK-LABEL: @constant_segment(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: ret i32 0
define i32 @constant_segment() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 24, i32 48, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 17, i32 0, i32 8)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @out_of_range(
; CHECK: @jeandle.new_array
; CHECK: call i32 @jeandle.vectorized_hashcode
; CHECK-NOT: poison
; CHECK: ret i32
define i32 @out_of_range() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 3, i32 2, i32 0, i32 8)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A partially overlapping i16 store makes the first byte cell unreadable; the
; fold must not commit anything.
; CHECK-LABEL: @overlapping_store(
; CHECK: @jeandle.new_array
; CHECK: store atomic i16 65
; CHECK: call i32 @jeandle.vectorized_hashcode
; CHECK-NOT: poison
; CHECK: ret i32
define i32 @overlapping_store() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i16 65, ptr addrspace(1) %p0 unordered, align 2
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 2, i32 0, i32 8)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @nonvirtual_receiver(
; CHECK: call i32 @jeandle.vectorized_hashcode
; CHECK-NOT: poison
; CHECK: ret i32
define i32 @nonvirtual_receiver(ptr addrspace(1) %ext) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %ext, i32 0, i32 2, i32 0, i32 10)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; utf16 composition needs both bytes of every pair constant.
; CHECK-LABEL: @utf16_unknown_cell(
; CHECK: @jeandle.new_array
; CHECK: call i32 @jeandle.vectorized_hashcode
; CHECK-NOT: poison
; CHECK: ret i32
define i32 @utf16_unknown_cell(i8 %v) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 17
  store atomic i8 %v, ptr addrspace(1) %p0 unordered, align 1
  store atomic i8 0, ptr addrspace(1) %p1 unordered, align 1
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 1, i32 0, i32 5)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}
