; RUN: opt -S -passes='partial-escape-iterative,instcombine,simplifycfg' -jeandle-pea-max-array-length=256 -jeandle-vm-callback-log=%S/Inputs/layout.cblog -verify-each %s | FileCheck %s
;
; Constant segments of a hash have bounded scalar cost even when the
; array has more than sixteen elements. Dynamic work remains bounded.
target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.int = constant i32 16
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @jeandle.vectorized_hashcode(ptr addrspace(1), i32, i32, i32, i32)
declare i32 @__gxx_personality_v0(...)

; CHECK-LABEL: @fresh_seventeen(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: mul i32 %v, 1353309697
; CHECK: ret i32
define i32 @fresh_seventeen(i32 %v) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 17, i32 88, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %v, ptr addrspace(1) %p0 unordered, align 4
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 20
  store atomic i32 1, ptr addrspace(1) %p1 unordered, align 4
  %p2 = getelementptr i8, ptr addrspace(1) %a, i64 24
  store atomic i32 2, ptr addrspace(1) %p2 unordered, align 4
  %p3 = getelementptr i8, ptr addrspace(1) %a, i64 28
  store atomic i32 3, ptr addrspace(1) %p3 unordered, align 4
  %p4 = getelementptr i8, ptr addrspace(1) %a, i64 32
  store atomic i32 4, ptr addrspace(1) %p4 unordered, align 4
  %p5 = getelementptr i8, ptr addrspace(1) %a, i64 36
  store atomic i32 5, ptr addrspace(1) %p5 unordered, align 4
  %p6 = getelementptr i8, ptr addrspace(1) %a, i64 40
  store atomic i32 6, ptr addrspace(1) %p6 unordered, align 4
  %p7 = getelementptr i8, ptr addrspace(1) %a, i64 44
  store atomic i32 7, ptr addrspace(1) %p7 unordered, align 4
  %p8 = getelementptr i8, ptr addrspace(1) %a, i64 48
  store atomic i32 8, ptr addrspace(1) %p8 unordered, align 4
  %p9 = getelementptr i8, ptr addrspace(1) %a, i64 52
  store atomic i32 9, ptr addrspace(1) %p9 unordered, align 4
  %p10 = getelementptr i8, ptr addrspace(1) %a, i64 56
  store atomic i32 10, ptr addrspace(1) %p10 unordered, align 4
  %p11 = getelementptr i8, ptr addrspace(1) %a, i64 60
  store atomic i32 11, ptr addrspace(1) %p11 unordered, align 4
  %p12 = getelementptr i8, ptr addrspace(1) %a, i64 64
  store atomic i32 12, ptr addrspace(1) %p12 unordered, align 4
  %p13 = getelementptr i8, ptr addrspace(1) %a, i64 68
  store atomic i32 13, ptr addrspace(1) %p13 unordered, align 4
  %p14 = getelementptr i8, ptr addrspace(1) %a, i64 72
  store atomic i32 14, ptr addrspace(1) %p14 unordered, align 4
  %p15 = getelementptr i8, ptr addrspace(1) %a, i64 76
  store atomic i32 15, ptr addrspace(1) %p15 unordered, align 4
  %p16 = getelementptr i8, ptr addrspace(1) %a, i64 80
  store atomic i32 16, ptr addrspace(1) %p16 unordered, align 4
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 17, i32 1, i32 10)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @constant_segment(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: mul i32 %v,
; CHECK: ret i32
define i32 @constant_segment(i32 %v) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 64, i32 272, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %v, ptr addrspace(1) %p0 unordered, align 4
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 64, i32 0, i32 10)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @nonzero_from(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: mul i32 %v, 1353309697
; CHECK: add i32
; CHECK: ret i32
define i32 @nonzero_from(i32 %v) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 18, i32 88, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 20
  store atomic i32 %v, ptr addrspace(1) %p1 unordered, align 4
  %p17 = getelementptr i8, ptr addrspace(1) %a, i64 84
  store atomic i32 -1, ptr addrspace(1) %p17 unordered, align 4
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 1, i32 17, i32 0, i32 10)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @constant_with_scalar_init(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: mul i32 %v, 2111290369
; CHECK: ret i32
define i32 @constant_with_scalar_init(i32 %v) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 32, i32 144, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 32, i32 %v, i32 10)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @scalar_cost_fallback(
; CHECK: @jeandle.new_array
; CHECK: call i32 @jeandle.vectorized_hashcode
; CHECK-NOT: poison
; CHECK: ret i32
define i32 @scalar_cost_fallback(i32 %v) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 40, i32 176, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %v, ptr addrspace(1) %p0 unordered, align 4
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 20
  store atomic i32 %v, ptr addrspace(1) %p1 unordered, align 4
  %p2 = getelementptr i8, ptr addrspace(1) %a, i64 24
  store atomic i32 %v, ptr addrspace(1) %p2 unordered, align 4
  %p3 = getelementptr i8, ptr addrspace(1) %a, i64 28
  store atomic i32 %v, ptr addrspace(1) %p3 unordered, align 4
  %p4 = getelementptr i8, ptr addrspace(1) %a, i64 32
  store atomic i32 %v, ptr addrspace(1) %p4 unordered, align 4
  %p5 = getelementptr i8, ptr addrspace(1) %a, i64 36
  store atomic i32 %v, ptr addrspace(1) %p5 unordered, align 4
  %p6 = getelementptr i8, ptr addrspace(1) %a, i64 40
  store atomic i32 %v, ptr addrspace(1) %p6 unordered, align 4
  %p7 = getelementptr i8, ptr addrspace(1) %a, i64 44
  store atomic i32 %v, ptr addrspace(1) %p7 unordered, align 4
  %p8 = getelementptr i8, ptr addrspace(1) %a, i64 48
  store atomic i32 %v, ptr addrspace(1) %p8 unordered, align 4
  %p9 = getelementptr i8, ptr addrspace(1) %a, i64 52
  store atomic i32 %v, ptr addrspace(1) %p9 unordered, align 4
  %p10 = getelementptr i8, ptr addrspace(1) %a, i64 56
  store atomic i32 %v, ptr addrspace(1) %p10 unordered, align 4
  %p11 = getelementptr i8, ptr addrspace(1) %a, i64 60
  store atomic i32 %v, ptr addrspace(1) %p11 unordered, align 4
  %p12 = getelementptr i8, ptr addrspace(1) %a, i64 64
  store atomic i32 %v, ptr addrspace(1) %p12 unordered, align 4
  %p13 = getelementptr i8, ptr addrspace(1) %a, i64 68
  store atomic i32 %v, ptr addrspace(1) %p13 unordered, align 4
  %p14 = getelementptr i8, ptr addrspace(1) %a, i64 72
  store atomic i32 %v, ptr addrspace(1) %p14 unordered, align 4
  %p15 = getelementptr i8, ptr addrspace(1) %a, i64 76
  store atomic i32 %v, ptr addrspace(1) %p15 unordered, align 4
  %p16 = getelementptr i8, ptr addrspace(1) %a, i64 80
  store atomic i32 %v, ptr addrspace(1) %p16 unordered, align 4
  %p17 = getelementptr i8, ptr addrspace(1) %a, i64 84
  store atomic i32 %v, ptr addrspace(1) %p17 unordered, align 4
  %p18 = getelementptr i8, ptr addrspace(1) %a, i64 88
  store atomic i32 %v, ptr addrspace(1) %p18 unordered, align 4
  %p19 = getelementptr i8, ptr addrspace(1) %a, i64 92
  store atomic i32 %v, ptr addrspace(1) %p19 unordered, align 4
  %p20 = getelementptr i8, ptr addrspace(1) %a, i64 96
  store atomic i32 %v, ptr addrspace(1) %p20 unordered, align 4
  %p21 = getelementptr i8, ptr addrspace(1) %a, i64 100
  store atomic i32 %v, ptr addrspace(1) %p21 unordered, align 4
  %p22 = getelementptr i8, ptr addrspace(1) %a, i64 104
  store atomic i32 %v, ptr addrspace(1) %p22 unordered, align 4
  %p23 = getelementptr i8, ptr addrspace(1) %a, i64 108
  store atomic i32 %v, ptr addrspace(1) %p23 unordered, align 4
  %p24 = getelementptr i8, ptr addrspace(1) %a, i64 112
  store atomic i32 %v, ptr addrspace(1) %p24 unordered, align 4
  %p25 = getelementptr i8, ptr addrspace(1) %a, i64 116
  store atomic i32 %v, ptr addrspace(1) %p25 unordered, align 4
  %p26 = getelementptr i8, ptr addrspace(1) %a, i64 120
  store atomic i32 %v, ptr addrspace(1) %p26 unordered, align 4
  %p27 = getelementptr i8, ptr addrspace(1) %a, i64 124
  store atomic i32 %v, ptr addrspace(1) %p27 unordered, align 4
  %p28 = getelementptr i8, ptr addrspace(1) %a, i64 128
  store atomic i32 %v, ptr addrspace(1) %p28 unordered, align 4
  %p29 = getelementptr i8, ptr addrspace(1) %a, i64 132
  store atomic i32 %v, ptr addrspace(1) %p29 unordered, align 4
  %p30 = getelementptr i8, ptr addrspace(1) %a, i64 136
  store atomic i32 %v, ptr addrspace(1) %p30 unordered, align 4
  %p31 = getelementptr i8, ptr addrspace(1) %a, i64 140
  store atomic i32 %v, ptr addrspace(1) %p31 unordered, align 4
  %p32 = getelementptr i8, ptr addrspace(1) %a, i64 144
  store atomic i32 %v, ptr addrspace(1) %p32 unordered, align 4
  %p33 = getelementptr i8, ptr addrspace(1) %a, i64 148
  store atomic i32 %v, ptr addrspace(1) %p33 unordered, align 4
  %p34 = getelementptr i8, ptr addrspace(1) %a, i64 152
  store atomic i32 %v, ptr addrspace(1) %p34 unordered, align 4
  %p35 = getelementptr i8, ptr addrspace(1) %a, i64 156
  store atomic i32 %v, ptr addrspace(1) %p35 unordered, align 4
  %p36 = getelementptr i8, ptr addrspace(1) %a, i64 160
  store atomic i32 %v, ptr addrspace(1) %p36 unordered, align 4
  %p37 = getelementptr i8, ptr addrspace(1) %a, i64 164
  store atomic i32 %v, ptr addrspace(1) %p37 unordered, align 4
  %p38 = getelementptr i8, ptr addrspace(1) %a, i64 168
  store atomic i32 %v, ptr addrspace(1) %p38 unordered, align 4
  %p39 = getelementptr i8, ptr addrspace(1) %a, i64 172
  store atomic i32 %v, ptr addrspace(1) %p39 unordered, align 4
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 40, i32 1, i32 10)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @scan_limit_fallback(
; CHECK: @jeandle.new_array
; CHECK: call i32 @jeandle.vectorized_hashcode
; CHECK-NOT: poison
; CHECK: ret i32
define i32 @scan_limit_fallback(i32 %v) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 129, i32 536, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 129, i32 0, i32 10)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @signed_constant_segments(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: sext i8 %v to i32
; CHECK: mul i32
; CHECK: add i32
; CHECK: ret i32
define i32 @signed_constant_segments(i8 %v, i32 %seed) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 24, i32 40, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i8 -128, ptr addrspace(1) %p0 unordered, align 1
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 17
  store atomic i8 %v, ptr addrspace(1) %p1 unordered, align 1
  %p23 = getelementptr i8, ptr addrspace(1) %a, i64 39
  store atomic i8 -1, ptr addrspace(1) %p23 unordered, align 1
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 24, i32 %seed, i32 8)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}
