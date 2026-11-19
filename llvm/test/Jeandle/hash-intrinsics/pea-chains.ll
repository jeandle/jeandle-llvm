; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform' -jeandle-pea-max-array-length=256 -jeandle-vm-callback-log=%S/Inputs/layout.cblog -verify-each %s | FileCheck %s --implicit-check-not='{{call|invoke}}{{.*}}@jeandle.new_array' --implicit-check-not='{{call|invoke}}{{.*}}@jeandle.vectorized_hashcode'
;
; Independent dynamic cells must stay virtual past the scalar-chain budget.
; Independent weighted vector groups and a balanced reduction avoid long
; multiply recurrences, including partial groups at lengths 22 and 33.
target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
@arrayOopDesc.base_offset_in_bytes.char = constant i32 16
@arrayOopDesc.base_offset_in_bytes.int = constant i32 16
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @jeandle.vectorized_hashcode(ptr addrspace(1), i32, i32, i32, i32)
declare i32 @__gxx_personality_v0(...)

; CHECK-LABEL: @byte22(
; CHECK: sext <4 x i8>
; CHECK-COUNT-6: mul <4 x i32>
; CHECK-NOT: mul <4 x i32>
; CHECK: shufflevector <4 x i32>
; CHECK: extractelement <4 x i32>
; CHECK: ret i32
define i32 @byte22(i8 %v0, i8 %v1, i8 %v2, i8 %v3, i8 %v4, i8 %v5, i8 %v6, i8 %v7, i8 %v8, i8 %v9, i8 %v10, i8 %v11, i8 %v12, i8 %v13, i8 %v14, i8 %v15, i8 %v16, i8 %v17, i8 %v18, i8 %v19, i8 %v20, i8 %v21, i32 %seed) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 22, i32 40, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i8 %v0, ptr addrspace(1) %p0 unordered, align 1
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 17
  store atomic i8 %v1, ptr addrspace(1) %p1 unordered, align 1
  %p2 = getelementptr i8, ptr addrspace(1) %a, i64 18
  store atomic i8 %v2, ptr addrspace(1) %p2 unordered, align 1
  %p3 = getelementptr i8, ptr addrspace(1) %a, i64 19
  store atomic i8 %v3, ptr addrspace(1) %p3 unordered, align 1
  %p4 = getelementptr i8, ptr addrspace(1) %a, i64 20
  store atomic i8 %v4, ptr addrspace(1) %p4 unordered, align 1
  %p5 = getelementptr i8, ptr addrspace(1) %a, i64 21
  store atomic i8 %v5, ptr addrspace(1) %p5 unordered, align 1
  %p6 = getelementptr i8, ptr addrspace(1) %a, i64 22
  store atomic i8 %v6, ptr addrspace(1) %p6 unordered, align 1
  %p7 = getelementptr i8, ptr addrspace(1) %a, i64 23
  store atomic i8 %v7, ptr addrspace(1) %p7 unordered, align 1
  %p8 = getelementptr i8, ptr addrspace(1) %a, i64 24
  store atomic i8 %v8, ptr addrspace(1) %p8 unordered, align 1
  %p9 = getelementptr i8, ptr addrspace(1) %a, i64 25
  store atomic i8 %v9, ptr addrspace(1) %p9 unordered, align 1
  %p10 = getelementptr i8, ptr addrspace(1) %a, i64 26
  store atomic i8 %v10, ptr addrspace(1) %p10 unordered, align 1
  %p11 = getelementptr i8, ptr addrspace(1) %a, i64 27
  store atomic i8 %v11, ptr addrspace(1) %p11 unordered, align 1
  %p12 = getelementptr i8, ptr addrspace(1) %a, i64 28
  store atomic i8 %v12, ptr addrspace(1) %p12 unordered, align 1
  %p13 = getelementptr i8, ptr addrspace(1) %a, i64 29
  store atomic i8 %v13, ptr addrspace(1) %p13 unordered, align 1
  %p14 = getelementptr i8, ptr addrspace(1) %a, i64 30
  store atomic i8 %v14, ptr addrspace(1) %p14 unordered, align 1
  %p15 = getelementptr i8, ptr addrspace(1) %a, i64 31
  store atomic i8 %v15, ptr addrspace(1) %p15 unordered, align 1
  %p16 = getelementptr i8, ptr addrspace(1) %a, i64 32
  store atomic i8 %v16, ptr addrspace(1) %p16 unordered, align 1
  %p17 = getelementptr i8, ptr addrspace(1) %a, i64 33
  store atomic i8 %v17, ptr addrspace(1) %p17 unordered, align 1
  %p18 = getelementptr i8, ptr addrspace(1) %a, i64 34
  store atomic i8 %v18, ptr addrspace(1) %p18 unordered, align 1
  %p19 = getelementptr i8, ptr addrspace(1) %a, i64 35
  store atomic i8 %v19, ptr addrspace(1) %p19 unordered, align 1
  %p20 = getelementptr i8, ptr addrspace(1) %a, i64 36
  store atomic i8 %v20, ptr addrspace(1) %p20 unordered, align 1
  %p21 = getelementptr i8, ptr addrspace(1) %a, i64 37
  store atomic i8 %v21, ptr addrspace(1) %p21 unordered, align 1
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 22, i32 %seed, i32 8)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @char22(
; CHECK: zext <4 x i16>
; CHECK-COUNT-6: mul <4 x i32>
; CHECK-NOT: mul <4 x i32>
; CHECK: shufflevector <4 x i32>
; CHECK: extractelement <4 x i32>
; CHECK: ret i32
define i32 @char22(i16 %v0, i16 %v1, i16 %v2, i16 %v3, i16 %v4, i16 %v5, i16 %v6, i16 %v7, i16 %v8, i16 %v9, i16 %v10, i16 %v11, i16 %v12, i16 %v13, i16 %v14, i16 %v15, i16 %v16, i16 %v17, i16 %v18, i16 %v19, i16 %v20, i16 %v21, i32 %seed) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 22, i32 64, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i16 %v0, ptr addrspace(1) %p0 unordered, align 2
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 18
  store atomic i16 %v1, ptr addrspace(1) %p1 unordered, align 2
  %p2 = getelementptr i8, ptr addrspace(1) %a, i64 20
  store atomic i16 %v2, ptr addrspace(1) %p2 unordered, align 2
  %p3 = getelementptr i8, ptr addrspace(1) %a, i64 22
  store atomic i16 %v3, ptr addrspace(1) %p3 unordered, align 2
  %p4 = getelementptr i8, ptr addrspace(1) %a, i64 24
  store atomic i16 %v4, ptr addrspace(1) %p4 unordered, align 2
  %p5 = getelementptr i8, ptr addrspace(1) %a, i64 26
  store atomic i16 %v5, ptr addrspace(1) %p5 unordered, align 2
  %p6 = getelementptr i8, ptr addrspace(1) %a, i64 28
  store atomic i16 %v6, ptr addrspace(1) %p6 unordered, align 2
  %p7 = getelementptr i8, ptr addrspace(1) %a, i64 30
  store atomic i16 %v7, ptr addrspace(1) %p7 unordered, align 2
  %p8 = getelementptr i8, ptr addrspace(1) %a, i64 32
  store atomic i16 %v8, ptr addrspace(1) %p8 unordered, align 2
  %p9 = getelementptr i8, ptr addrspace(1) %a, i64 34
  store atomic i16 %v9, ptr addrspace(1) %p9 unordered, align 2
  %p10 = getelementptr i8, ptr addrspace(1) %a, i64 36
  store atomic i16 %v10, ptr addrspace(1) %p10 unordered, align 2
  %p11 = getelementptr i8, ptr addrspace(1) %a, i64 38
  store atomic i16 %v11, ptr addrspace(1) %p11 unordered, align 2
  %p12 = getelementptr i8, ptr addrspace(1) %a, i64 40
  store atomic i16 %v12, ptr addrspace(1) %p12 unordered, align 2
  %p13 = getelementptr i8, ptr addrspace(1) %a, i64 42
  store atomic i16 %v13, ptr addrspace(1) %p13 unordered, align 2
  %p14 = getelementptr i8, ptr addrspace(1) %a, i64 44
  store atomic i16 %v14, ptr addrspace(1) %p14 unordered, align 2
  %p15 = getelementptr i8, ptr addrspace(1) %a, i64 46
  store atomic i16 %v15, ptr addrspace(1) %p15 unordered, align 2
  %p16 = getelementptr i8, ptr addrspace(1) %a, i64 48
  store atomic i16 %v16, ptr addrspace(1) %p16 unordered, align 2
  %p17 = getelementptr i8, ptr addrspace(1) %a, i64 50
  store atomic i16 %v17, ptr addrspace(1) %p17 unordered, align 2
  %p18 = getelementptr i8, ptr addrspace(1) %a, i64 52
  store atomic i16 %v18, ptr addrspace(1) %p18 unordered, align 2
  %p19 = getelementptr i8, ptr addrspace(1) %a, i64 54
  store atomic i16 %v19, ptr addrspace(1) %p19 unordered, align 2
  %p20 = getelementptr i8, ptr addrspace(1) %a, i64 56
  store atomic i16 %v20, ptr addrspace(1) %p20 unordered, align 2
  %p21 = getelementptr i8, ptr addrspace(1) %a, i64 58
  store atomic i16 %v21, ptr addrspace(1) %p21 unordered, align 2
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 22, i32 %seed, i32 5)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @int33(
; CHECK-COUNT-9: mul <4 x i32>
; CHECK-NOT: mul <4 x i32>
; CHECK: shufflevector <4 x i32>
; CHECK: extractelement <4 x i32>
; CHECK: ret i32
define i32 @int33(i32 %v0, i32 %v1, i32 %v2, i32 %v3, i32 %v4, i32 %v5, i32 %v6, i32 %v7, i32 %v8, i32 %v9, i32 %v10, i32 %v11, i32 %v12, i32 %v13, i32 %v14, i32 %v15, i32 %v16, i32 %v17, i32 %v18, i32 %v19, i32 %v20, i32 %v21, i32 %v22, i32 %v23, i32 %v24, i32 %v25, i32 %v26, i32 %v27, i32 %v28, i32 %v29, i32 %v30, i32 %v31, i32 %v32, i32 %seed) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 33, i32 152, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %v0, ptr addrspace(1) %p0 unordered, align 4
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 20
  store atomic i32 %v1, ptr addrspace(1) %p1 unordered, align 4
  %p2 = getelementptr i8, ptr addrspace(1) %a, i64 24
  store atomic i32 %v2, ptr addrspace(1) %p2 unordered, align 4
  %p3 = getelementptr i8, ptr addrspace(1) %a, i64 28
  store atomic i32 %v3, ptr addrspace(1) %p3 unordered, align 4
  %p4 = getelementptr i8, ptr addrspace(1) %a, i64 32
  store atomic i32 %v4, ptr addrspace(1) %p4 unordered, align 4
  %p5 = getelementptr i8, ptr addrspace(1) %a, i64 36
  store atomic i32 %v5, ptr addrspace(1) %p5 unordered, align 4
  %p6 = getelementptr i8, ptr addrspace(1) %a, i64 40
  store atomic i32 %v6, ptr addrspace(1) %p6 unordered, align 4
  %p7 = getelementptr i8, ptr addrspace(1) %a, i64 44
  store atomic i32 %v7, ptr addrspace(1) %p7 unordered, align 4
  %p8 = getelementptr i8, ptr addrspace(1) %a, i64 48
  store atomic i32 %v8, ptr addrspace(1) %p8 unordered, align 4
  %p9 = getelementptr i8, ptr addrspace(1) %a, i64 52
  store atomic i32 %v9, ptr addrspace(1) %p9 unordered, align 4
  %p10 = getelementptr i8, ptr addrspace(1) %a, i64 56
  store atomic i32 %v10, ptr addrspace(1) %p10 unordered, align 4
  %p11 = getelementptr i8, ptr addrspace(1) %a, i64 60
  store atomic i32 %v11, ptr addrspace(1) %p11 unordered, align 4
  %p12 = getelementptr i8, ptr addrspace(1) %a, i64 64
  store atomic i32 %v12, ptr addrspace(1) %p12 unordered, align 4
  %p13 = getelementptr i8, ptr addrspace(1) %a, i64 68
  store atomic i32 %v13, ptr addrspace(1) %p13 unordered, align 4
  %p14 = getelementptr i8, ptr addrspace(1) %a, i64 72
  store atomic i32 %v14, ptr addrspace(1) %p14 unordered, align 4
  %p15 = getelementptr i8, ptr addrspace(1) %a, i64 76
  store atomic i32 %v15, ptr addrspace(1) %p15 unordered, align 4
  %p16 = getelementptr i8, ptr addrspace(1) %a, i64 80
  store atomic i32 %v16, ptr addrspace(1) %p16 unordered, align 4
  %p17 = getelementptr i8, ptr addrspace(1) %a, i64 84
  store atomic i32 %v17, ptr addrspace(1) %p17 unordered, align 4
  %p18 = getelementptr i8, ptr addrspace(1) %a, i64 88
  store atomic i32 %v18, ptr addrspace(1) %p18 unordered, align 4
  %p19 = getelementptr i8, ptr addrspace(1) %a, i64 92
  store atomic i32 %v19, ptr addrspace(1) %p19 unordered, align 4
  %p20 = getelementptr i8, ptr addrspace(1) %a, i64 96
  store atomic i32 %v20, ptr addrspace(1) %p20 unordered, align 4
  %p21 = getelementptr i8, ptr addrspace(1) %a, i64 100
  store atomic i32 %v21, ptr addrspace(1) %p21 unordered, align 4
  %p22 = getelementptr i8, ptr addrspace(1) %a, i64 104
  store atomic i32 %v22, ptr addrspace(1) %p22 unordered, align 4
  %p23 = getelementptr i8, ptr addrspace(1) %a, i64 108
  store atomic i32 %v23, ptr addrspace(1) %p23 unordered, align 4
  %p24 = getelementptr i8, ptr addrspace(1) %a, i64 112
  store atomic i32 %v24, ptr addrspace(1) %p24 unordered, align 4
  %p25 = getelementptr i8, ptr addrspace(1) %a, i64 116
  store atomic i32 %v25, ptr addrspace(1) %p25 unordered, align 4
  %p26 = getelementptr i8, ptr addrspace(1) %a, i64 120
  store atomic i32 %v26, ptr addrspace(1) %p26 unordered, align 4
  %p27 = getelementptr i8, ptr addrspace(1) %a, i64 124
  store atomic i32 %v27, ptr addrspace(1) %p27 unordered, align 4
  %p28 = getelementptr i8, ptr addrspace(1) %a, i64 128
  store atomic i32 %v28, ptr addrspace(1) %p28 unordered, align 4
  %p29 = getelementptr i8, ptr addrspace(1) %a, i64 132
  store atomic i32 %v29, ptr addrspace(1) %p29 unordered, align 4
  %p30 = getelementptr i8, ptr addrspace(1) %a, i64 136
  store atomic i32 %v30, ptr addrspace(1) %p30 unordered, align 4
  %p31 = getelementptr i8, ptr addrspace(1) %a, i64 140
  store atomic i32 %v31, ptr addrspace(1) %p31 unordered, align 4
  %p32 = getelementptr i8, ptr addrspace(1) %a, i64 144
  store atomic i32 %v32, ptr addrspace(1) %p32 unordered, align 4
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 33, i32 %seed, i32 10)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @int40(
; CHECK-COUNT-10: mul <4 x i32>
; CHECK-NOT: mul <4 x i32>
; CHECK: shufflevector <4 x i32>
; CHECK: extractelement <4 x i32>
; CHECK: ret i32
define i32 @int40(i32 %v0, i32 %v1, i32 %v2, i32 %v3, i32 %v4, i32 %v5, i32 %v6, i32 %v7, i32 %v8, i32 %v9, i32 %v10, i32 %v11, i32 %v12, i32 %v13, i32 %v14, i32 %v15, i32 %v16, i32 %v17, i32 %v18, i32 %v19, i32 %v20, i32 %v21, i32 %v22, i32 %v23, i32 %v24, i32 %v25, i32 %v26, i32 %v27, i32 %v28, i32 %v29, i32 %v30, i32 %v31, i32 %v32, i32 %v33, i32 %v34, i32 %v35, i32 %v36, i32 %v37, i32 %v38, i32 %v39, i32 %seed) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 40, i32 176, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %v0, ptr addrspace(1) %p0 unordered, align 4
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 20
  store atomic i32 %v1, ptr addrspace(1) %p1 unordered, align 4
  %p2 = getelementptr i8, ptr addrspace(1) %a, i64 24
  store atomic i32 %v2, ptr addrspace(1) %p2 unordered, align 4
  %p3 = getelementptr i8, ptr addrspace(1) %a, i64 28
  store atomic i32 %v3, ptr addrspace(1) %p3 unordered, align 4
  %p4 = getelementptr i8, ptr addrspace(1) %a, i64 32
  store atomic i32 %v4, ptr addrspace(1) %p4 unordered, align 4
  %p5 = getelementptr i8, ptr addrspace(1) %a, i64 36
  store atomic i32 %v5, ptr addrspace(1) %p5 unordered, align 4
  %p6 = getelementptr i8, ptr addrspace(1) %a, i64 40
  store atomic i32 %v6, ptr addrspace(1) %p6 unordered, align 4
  %p7 = getelementptr i8, ptr addrspace(1) %a, i64 44
  store atomic i32 %v7, ptr addrspace(1) %p7 unordered, align 4
  %p8 = getelementptr i8, ptr addrspace(1) %a, i64 48
  store atomic i32 %v8, ptr addrspace(1) %p8 unordered, align 4
  %p9 = getelementptr i8, ptr addrspace(1) %a, i64 52
  store atomic i32 %v9, ptr addrspace(1) %p9 unordered, align 4
  %p10 = getelementptr i8, ptr addrspace(1) %a, i64 56
  store atomic i32 %v10, ptr addrspace(1) %p10 unordered, align 4
  %p11 = getelementptr i8, ptr addrspace(1) %a, i64 60
  store atomic i32 %v11, ptr addrspace(1) %p11 unordered, align 4
  %p12 = getelementptr i8, ptr addrspace(1) %a, i64 64
  store atomic i32 %v12, ptr addrspace(1) %p12 unordered, align 4
  %p13 = getelementptr i8, ptr addrspace(1) %a, i64 68
  store atomic i32 %v13, ptr addrspace(1) %p13 unordered, align 4
  %p14 = getelementptr i8, ptr addrspace(1) %a, i64 72
  store atomic i32 %v14, ptr addrspace(1) %p14 unordered, align 4
  %p15 = getelementptr i8, ptr addrspace(1) %a, i64 76
  store atomic i32 %v15, ptr addrspace(1) %p15 unordered, align 4
  %p16 = getelementptr i8, ptr addrspace(1) %a, i64 80
  store atomic i32 %v16, ptr addrspace(1) %p16 unordered, align 4
  %p17 = getelementptr i8, ptr addrspace(1) %a, i64 84
  store atomic i32 %v17, ptr addrspace(1) %p17 unordered, align 4
  %p18 = getelementptr i8, ptr addrspace(1) %a, i64 88
  store atomic i32 %v18, ptr addrspace(1) %p18 unordered, align 4
  %p19 = getelementptr i8, ptr addrspace(1) %a, i64 92
  store atomic i32 %v19, ptr addrspace(1) %p19 unordered, align 4
  %p20 = getelementptr i8, ptr addrspace(1) %a, i64 96
  store atomic i32 %v20, ptr addrspace(1) %p20 unordered, align 4
  %p21 = getelementptr i8, ptr addrspace(1) %a, i64 100
  store atomic i32 %v21, ptr addrspace(1) %p21 unordered, align 4
  %p22 = getelementptr i8, ptr addrspace(1) %a, i64 104
  store atomic i32 %v22, ptr addrspace(1) %p22 unordered, align 4
  %p23 = getelementptr i8, ptr addrspace(1) %a, i64 108
  store atomic i32 %v23, ptr addrspace(1) %p23 unordered, align 4
  %p24 = getelementptr i8, ptr addrspace(1) %a, i64 112
  store atomic i32 %v24, ptr addrspace(1) %p24 unordered, align 4
  %p25 = getelementptr i8, ptr addrspace(1) %a, i64 116
  store atomic i32 %v25, ptr addrspace(1) %p25 unordered, align 4
  %p26 = getelementptr i8, ptr addrspace(1) %a, i64 120
  store atomic i32 %v26, ptr addrspace(1) %p26 unordered, align 4
  %p27 = getelementptr i8, ptr addrspace(1) %a, i64 124
  store atomic i32 %v27, ptr addrspace(1) %p27 unordered, align 4
  %p28 = getelementptr i8, ptr addrspace(1) %a, i64 128
  store atomic i32 %v28, ptr addrspace(1) %p28 unordered, align 4
  %p29 = getelementptr i8, ptr addrspace(1) %a, i64 132
  store atomic i32 %v29, ptr addrspace(1) %p29 unordered, align 4
  %p30 = getelementptr i8, ptr addrspace(1) %a, i64 136
  store atomic i32 %v30, ptr addrspace(1) %p30 unordered, align 4
  %p31 = getelementptr i8, ptr addrspace(1) %a, i64 140
  store atomic i32 %v31, ptr addrspace(1) %p31 unordered, align 4
  %p32 = getelementptr i8, ptr addrspace(1) %a, i64 144
  store atomic i32 %v32, ptr addrspace(1) %p32 unordered, align 4
  %p33 = getelementptr i8, ptr addrspace(1) %a, i64 148
  store atomic i32 %v33, ptr addrspace(1) %p33 unordered, align 4
  %p34 = getelementptr i8, ptr addrspace(1) %a, i64 152
  store atomic i32 %v34, ptr addrspace(1) %p34 unordered, align 4
  %p35 = getelementptr i8, ptr addrspace(1) %a, i64 156
  store atomic i32 %v35, ptr addrspace(1) %p35 unordered, align 4
  %p36 = getelementptr i8, ptr addrspace(1) %a, i64 160
  store atomic i32 %v36, ptr addrspace(1) %p36 unordered, align 4
  %p37 = getelementptr i8, ptr addrspace(1) %a, i64 164
  store atomic i32 %v37, ptr addrspace(1) %p37 unordered, align 4
  %p38 = getelementptr i8, ptr addrspace(1) %a, i64 168
  store atomic i32 %v38, ptr addrspace(1) %p38 unordered, align 4
  %p39 = getelementptr i8, ptr addrspace(1) %a, i64 172
  store atomic i32 %v39, ptr addrspace(1) %p39 unordered, align 4
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 40, i32 %seed, i32 10)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @int128(
; CHECK-COUNT-32: mul <4 x i32>
; CHECK-NOT: mul <4 x i32>
; CHECK: shufflevector <4 x i32>
; CHECK: extractelement <4 x i32>
; CHECK: ret i32
define i32 @int128(i32 %v0, i32 %v1, i32 %v2, i32 %v3, i32 %v4, i32 %v5, i32 %v6, i32 %v7, i32 %v8, i32 %v9, i32 %v10, i32 %v11, i32 %v12, i32 %v13, i32 %v14, i32 %v15, i32 %v16, i32 %v17, i32 %v18, i32 %v19, i32 %v20, i32 %v21, i32 %v22, i32 %v23, i32 %v24, i32 %v25, i32 %v26, i32 %v27, i32 %v28, i32 %v29, i32 %v30, i32 %v31, i32 %v32, i32 %v33, i32 %v34, i32 %v35, i32 %v36, i32 %v37, i32 %v38, i32 %v39, i32 %v40, i32 %v41, i32 %v42, i32 %v43, i32 %v44, i32 %v45, i32 %v46, i32 %v47, i32 %v48, i32 %v49, i32 %v50, i32 %v51, i32 %v52, i32 %v53, i32 %v54, i32 %v55, i32 %v56, i32 %v57, i32 %v58, i32 %v59, i32 %v60, i32 %v61, i32 %v62, i32 %v63, i32 %v64, i32 %v65, i32 %v66, i32 %v67, i32 %v68, i32 %v69, i32 %v70, i32 %v71, i32 %v72, i32 %v73, i32 %v74, i32 %v75, i32 %v76, i32 %v77, i32 %v78, i32 %v79, i32 %v80, i32 %v81, i32 %v82, i32 %v83, i32 %v84, i32 %v85, i32 %v86, i32 %v87, i32 %v88, i32 %v89, i32 %v90, i32 %v91, i32 %v92, i32 %v93, i32 %v94, i32 %v95, i32 %v96, i32 %v97, i32 %v98, i32 %v99, i32 %v100, i32 %v101, i32 %v102, i32 %v103, i32 %v104, i32 %v105, i32 %v106, i32 %v107, i32 %v108, i32 %v109, i32 %v110, i32 %v111, i32 %v112, i32 %v113, i32 %v114, i32 %v115, i32 %v116, i32 %v117, i32 %v118, i32 %v119, i32 %v120, i32 %v121, i32 %v122, i32 %v123, i32 %v124, i32 %v125, i32 %v126, i32 %v127, i32 %seed) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 128, i32 528, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %v0, ptr addrspace(1) %p0 unordered, align 4
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 20
  store atomic i32 %v1, ptr addrspace(1) %p1 unordered, align 4
  %p2 = getelementptr i8, ptr addrspace(1) %a, i64 24
  store atomic i32 %v2, ptr addrspace(1) %p2 unordered, align 4
  %p3 = getelementptr i8, ptr addrspace(1) %a, i64 28
  store atomic i32 %v3, ptr addrspace(1) %p3 unordered, align 4
  %p4 = getelementptr i8, ptr addrspace(1) %a, i64 32
  store atomic i32 %v4, ptr addrspace(1) %p4 unordered, align 4
  %p5 = getelementptr i8, ptr addrspace(1) %a, i64 36
  store atomic i32 %v5, ptr addrspace(1) %p5 unordered, align 4
  %p6 = getelementptr i8, ptr addrspace(1) %a, i64 40
  store atomic i32 %v6, ptr addrspace(1) %p6 unordered, align 4
  %p7 = getelementptr i8, ptr addrspace(1) %a, i64 44
  store atomic i32 %v7, ptr addrspace(1) %p7 unordered, align 4
  %p8 = getelementptr i8, ptr addrspace(1) %a, i64 48
  store atomic i32 %v8, ptr addrspace(1) %p8 unordered, align 4
  %p9 = getelementptr i8, ptr addrspace(1) %a, i64 52
  store atomic i32 %v9, ptr addrspace(1) %p9 unordered, align 4
  %p10 = getelementptr i8, ptr addrspace(1) %a, i64 56
  store atomic i32 %v10, ptr addrspace(1) %p10 unordered, align 4
  %p11 = getelementptr i8, ptr addrspace(1) %a, i64 60
  store atomic i32 %v11, ptr addrspace(1) %p11 unordered, align 4
  %p12 = getelementptr i8, ptr addrspace(1) %a, i64 64
  store atomic i32 %v12, ptr addrspace(1) %p12 unordered, align 4
  %p13 = getelementptr i8, ptr addrspace(1) %a, i64 68
  store atomic i32 %v13, ptr addrspace(1) %p13 unordered, align 4
  %p14 = getelementptr i8, ptr addrspace(1) %a, i64 72
  store atomic i32 %v14, ptr addrspace(1) %p14 unordered, align 4
  %p15 = getelementptr i8, ptr addrspace(1) %a, i64 76
  store atomic i32 %v15, ptr addrspace(1) %p15 unordered, align 4
  %p16 = getelementptr i8, ptr addrspace(1) %a, i64 80
  store atomic i32 %v16, ptr addrspace(1) %p16 unordered, align 4
  %p17 = getelementptr i8, ptr addrspace(1) %a, i64 84
  store atomic i32 %v17, ptr addrspace(1) %p17 unordered, align 4
  %p18 = getelementptr i8, ptr addrspace(1) %a, i64 88
  store atomic i32 %v18, ptr addrspace(1) %p18 unordered, align 4
  %p19 = getelementptr i8, ptr addrspace(1) %a, i64 92
  store atomic i32 %v19, ptr addrspace(1) %p19 unordered, align 4
  %p20 = getelementptr i8, ptr addrspace(1) %a, i64 96
  store atomic i32 %v20, ptr addrspace(1) %p20 unordered, align 4
  %p21 = getelementptr i8, ptr addrspace(1) %a, i64 100
  store atomic i32 %v21, ptr addrspace(1) %p21 unordered, align 4
  %p22 = getelementptr i8, ptr addrspace(1) %a, i64 104
  store atomic i32 %v22, ptr addrspace(1) %p22 unordered, align 4
  %p23 = getelementptr i8, ptr addrspace(1) %a, i64 108
  store atomic i32 %v23, ptr addrspace(1) %p23 unordered, align 4
  %p24 = getelementptr i8, ptr addrspace(1) %a, i64 112
  store atomic i32 %v24, ptr addrspace(1) %p24 unordered, align 4
  %p25 = getelementptr i8, ptr addrspace(1) %a, i64 116
  store atomic i32 %v25, ptr addrspace(1) %p25 unordered, align 4
  %p26 = getelementptr i8, ptr addrspace(1) %a, i64 120
  store atomic i32 %v26, ptr addrspace(1) %p26 unordered, align 4
  %p27 = getelementptr i8, ptr addrspace(1) %a, i64 124
  store atomic i32 %v27, ptr addrspace(1) %p27 unordered, align 4
  %p28 = getelementptr i8, ptr addrspace(1) %a, i64 128
  store atomic i32 %v28, ptr addrspace(1) %p28 unordered, align 4
  %p29 = getelementptr i8, ptr addrspace(1) %a, i64 132
  store atomic i32 %v29, ptr addrspace(1) %p29 unordered, align 4
  %p30 = getelementptr i8, ptr addrspace(1) %a, i64 136
  store atomic i32 %v30, ptr addrspace(1) %p30 unordered, align 4
  %p31 = getelementptr i8, ptr addrspace(1) %a, i64 140
  store atomic i32 %v31, ptr addrspace(1) %p31 unordered, align 4
  %p32 = getelementptr i8, ptr addrspace(1) %a, i64 144
  store atomic i32 %v32, ptr addrspace(1) %p32 unordered, align 4
  %p33 = getelementptr i8, ptr addrspace(1) %a, i64 148
  store atomic i32 %v33, ptr addrspace(1) %p33 unordered, align 4
  %p34 = getelementptr i8, ptr addrspace(1) %a, i64 152
  store atomic i32 %v34, ptr addrspace(1) %p34 unordered, align 4
  %p35 = getelementptr i8, ptr addrspace(1) %a, i64 156
  store atomic i32 %v35, ptr addrspace(1) %p35 unordered, align 4
  %p36 = getelementptr i8, ptr addrspace(1) %a, i64 160
  store atomic i32 %v36, ptr addrspace(1) %p36 unordered, align 4
  %p37 = getelementptr i8, ptr addrspace(1) %a, i64 164
  store atomic i32 %v37, ptr addrspace(1) %p37 unordered, align 4
  %p38 = getelementptr i8, ptr addrspace(1) %a, i64 168
  store atomic i32 %v38, ptr addrspace(1) %p38 unordered, align 4
  %p39 = getelementptr i8, ptr addrspace(1) %a, i64 172
  store atomic i32 %v39, ptr addrspace(1) %p39 unordered, align 4
  %p40 = getelementptr i8, ptr addrspace(1) %a, i64 176
  store atomic i32 %v40, ptr addrspace(1) %p40 unordered, align 4
  %p41 = getelementptr i8, ptr addrspace(1) %a, i64 180
  store atomic i32 %v41, ptr addrspace(1) %p41 unordered, align 4
  %p42 = getelementptr i8, ptr addrspace(1) %a, i64 184
  store atomic i32 %v42, ptr addrspace(1) %p42 unordered, align 4
  %p43 = getelementptr i8, ptr addrspace(1) %a, i64 188
  store atomic i32 %v43, ptr addrspace(1) %p43 unordered, align 4
  %p44 = getelementptr i8, ptr addrspace(1) %a, i64 192
  store atomic i32 %v44, ptr addrspace(1) %p44 unordered, align 4
  %p45 = getelementptr i8, ptr addrspace(1) %a, i64 196
  store atomic i32 %v45, ptr addrspace(1) %p45 unordered, align 4
  %p46 = getelementptr i8, ptr addrspace(1) %a, i64 200
  store atomic i32 %v46, ptr addrspace(1) %p46 unordered, align 4
  %p47 = getelementptr i8, ptr addrspace(1) %a, i64 204
  store atomic i32 %v47, ptr addrspace(1) %p47 unordered, align 4
  %p48 = getelementptr i8, ptr addrspace(1) %a, i64 208
  store atomic i32 %v48, ptr addrspace(1) %p48 unordered, align 4
  %p49 = getelementptr i8, ptr addrspace(1) %a, i64 212
  store atomic i32 %v49, ptr addrspace(1) %p49 unordered, align 4
  %p50 = getelementptr i8, ptr addrspace(1) %a, i64 216
  store atomic i32 %v50, ptr addrspace(1) %p50 unordered, align 4
  %p51 = getelementptr i8, ptr addrspace(1) %a, i64 220
  store atomic i32 %v51, ptr addrspace(1) %p51 unordered, align 4
  %p52 = getelementptr i8, ptr addrspace(1) %a, i64 224
  store atomic i32 %v52, ptr addrspace(1) %p52 unordered, align 4
  %p53 = getelementptr i8, ptr addrspace(1) %a, i64 228
  store atomic i32 %v53, ptr addrspace(1) %p53 unordered, align 4
  %p54 = getelementptr i8, ptr addrspace(1) %a, i64 232
  store atomic i32 %v54, ptr addrspace(1) %p54 unordered, align 4
  %p55 = getelementptr i8, ptr addrspace(1) %a, i64 236
  store atomic i32 %v55, ptr addrspace(1) %p55 unordered, align 4
  %p56 = getelementptr i8, ptr addrspace(1) %a, i64 240
  store atomic i32 %v56, ptr addrspace(1) %p56 unordered, align 4
  %p57 = getelementptr i8, ptr addrspace(1) %a, i64 244
  store atomic i32 %v57, ptr addrspace(1) %p57 unordered, align 4
  %p58 = getelementptr i8, ptr addrspace(1) %a, i64 248
  store atomic i32 %v58, ptr addrspace(1) %p58 unordered, align 4
  %p59 = getelementptr i8, ptr addrspace(1) %a, i64 252
  store atomic i32 %v59, ptr addrspace(1) %p59 unordered, align 4
  %p60 = getelementptr i8, ptr addrspace(1) %a, i64 256
  store atomic i32 %v60, ptr addrspace(1) %p60 unordered, align 4
  %p61 = getelementptr i8, ptr addrspace(1) %a, i64 260
  store atomic i32 %v61, ptr addrspace(1) %p61 unordered, align 4
  %p62 = getelementptr i8, ptr addrspace(1) %a, i64 264
  store atomic i32 %v62, ptr addrspace(1) %p62 unordered, align 4
  %p63 = getelementptr i8, ptr addrspace(1) %a, i64 268
  store atomic i32 %v63, ptr addrspace(1) %p63 unordered, align 4
  %p64 = getelementptr i8, ptr addrspace(1) %a, i64 272
  store atomic i32 %v64, ptr addrspace(1) %p64 unordered, align 4
  %p65 = getelementptr i8, ptr addrspace(1) %a, i64 276
  store atomic i32 %v65, ptr addrspace(1) %p65 unordered, align 4
  %p66 = getelementptr i8, ptr addrspace(1) %a, i64 280
  store atomic i32 %v66, ptr addrspace(1) %p66 unordered, align 4
  %p67 = getelementptr i8, ptr addrspace(1) %a, i64 284
  store atomic i32 %v67, ptr addrspace(1) %p67 unordered, align 4
  %p68 = getelementptr i8, ptr addrspace(1) %a, i64 288
  store atomic i32 %v68, ptr addrspace(1) %p68 unordered, align 4
  %p69 = getelementptr i8, ptr addrspace(1) %a, i64 292
  store atomic i32 %v69, ptr addrspace(1) %p69 unordered, align 4
  %p70 = getelementptr i8, ptr addrspace(1) %a, i64 296
  store atomic i32 %v70, ptr addrspace(1) %p70 unordered, align 4
  %p71 = getelementptr i8, ptr addrspace(1) %a, i64 300
  store atomic i32 %v71, ptr addrspace(1) %p71 unordered, align 4
  %p72 = getelementptr i8, ptr addrspace(1) %a, i64 304
  store atomic i32 %v72, ptr addrspace(1) %p72 unordered, align 4
  %p73 = getelementptr i8, ptr addrspace(1) %a, i64 308
  store atomic i32 %v73, ptr addrspace(1) %p73 unordered, align 4
  %p74 = getelementptr i8, ptr addrspace(1) %a, i64 312
  store atomic i32 %v74, ptr addrspace(1) %p74 unordered, align 4
  %p75 = getelementptr i8, ptr addrspace(1) %a, i64 316
  store atomic i32 %v75, ptr addrspace(1) %p75 unordered, align 4
  %p76 = getelementptr i8, ptr addrspace(1) %a, i64 320
  store atomic i32 %v76, ptr addrspace(1) %p76 unordered, align 4
  %p77 = getelementptr i8, ptr addrspace(1) %a, i64 324
  store atomic i32 %v77, ptr addrspace(1) %p77 unordered, align 4
  %p78 = getelementptr i8, ptr addrspace(1) %a, i64 328
  store atomic i32 %v78, ptr addrspace(1) %p78 unordered, align 4
  %p79 = getelementptr i8, ptr addrspace(1) %a, i64 332
  store atomic i32 %v79, ptr addrspace(1) %p79 unordered, align 4
  %p80 = getelementptr i8, ptr addrspace(1) %a, i64 336
  store atomic i32 %v80, ptr addrspace(1) %p80 unordered, align 4
  %p81 = getelementptr i8, ptr addrspace(1) %a, i64 340
  store atomic i32 %v81, ptr addrspace(1) %p81 unordered, align 4
  %p82 = getelementptr i8, ptr addrspace(1) %a, i64 344
  store atomic i32 %v82, ptr addrspace(1) %p82 unordered, align 4
  %p83 = getelementptr i8, ptr addrspace(1) %a, i64 348
  store atomic i32 %v83, ptr addrspace(1) %p83 unordered, align 4
  %p84 = getelementptr i8, ptr addrspace(1) %a, i64 352
  store atomic i32 %v84, ptr addrspace(1) %p84 unordered, align 4
  %p85 = getelementptr i8, ptr addrspace(1) %a, i64 356
  store atomic i32 %v85, ptr addrspace(1) %p85 unordered, align 4
  %p86 = getelementptr i8, ptr addrspace(1) %a, i64 360
  store atomic i32 %v86, ptr addrspace(1) %p86 unordered, align 4
  %p87 = getelementptr i8, ptr addrspace(1) %a, i64 364
  store atomic i32 %v87, ptr addrspace(1) %p87 unordered, align 4
  %p88 = getelementptr i8, ptr addrspace(1) %a, i64 368
  store atomic i32 %v88, ptr addrspace(1) %p88 unordered, align 4
  %p89 = getelementptr i8, ptr addrspace(1) %a, i64 372
  store atomic i32 %v89, ptr addrspace(1) %p89 unordered, align 4
  %p90 = getelementptr i8, ptr addrspace(1) %a, i64 376
  store atomic i32 %v90, ptr addrspace(1) %p90 unordered, align 4
  %p91 = getelementptr i8, ptr addrspace(1) %a, i64 380
  store atomic i32 %v91, ptr addrspace(1) %p91 unordered, align 4
  %p92 = getelementptr i8, ptr addrspace(1) %a, i64 384
  store atomic i32 %v92, ptr addrspace(1) %p92 unordered, align 4
  %p93 = getelementptr i8, ptr addrspace(1) %a, i64 388
  store atomic i32 %v93, ptr addrspace(1) %p93 unordered, align 4
  %p94 = getelementptr i8, ptr addrspace(1) %a, i64 392
  store atomic i32 %v94, ptr addrspace(1) %p94 unordered, align 4
  %p95 = getelementptr i8, ptr addrspace(1) %a, i64 396
  store atomic i32 %v95, ptr addrspace(1) %p95 unordered, align 4
  %p96 = getelementptr i8, ptr addrspace(1) %a, i64 400
  store atomic i32 %v96, ptr addrspace(1) %p96 unordered, align 4
  %p97 = getelementptr i8, ptr addrspace(1) %a, i64 404
  store atomic i32 %v97, ptr addrspace(1) %p97 unordered, align 4
  %p98 = getelementptr i8, ptr addrspace(1) %a, i64 408
  store atomic i32 %v98, ptr addrspace(1) %p98 unordered, align 4
  %p99 = getelementptr i8, ptr addrspace(1) %a, i64 412
  store atomic i32 %v99, ptr addrspace(1) %p99 unordered, align 4
  %p100 = getelementptr i8, ptr addrspace(1) %a, i64 416
  store atomic i32 %v100, ptr addrspace(1) %p100 unordered, align 4
  %p101 = getelementptr i8, ptr addrspace(1) %a, i64 420
  store atomic i32 %v101, ptr addrspace(1) %p101 unordered, align 4
  %p102 = getelementptr i8, ptr addrspace(1) %a, i64 424
  store atomic i32 %v102, ptr addrspace(1) %p102 unordered, align 4
  %p103 = getelementptr i8, ptr addrspace(1) %a, i64 428
  store atomic i32 %v103, ptr addrspace(1) %p103 unordered, align 4
  %p104 = getelementptr i8, ptr addrspace(1) %a, i64 432
  store atomic i32 %v104, ptr addrspace(1) %p104 unordered, align 4
  %p105 = getelementptr i8, ptr addrspace(1) %a, i64 436
  store atomic i32 %v105, ptr addrspace(1) %p105 unordered, align 4
  %p106 = getelementptr i8, ptr addrspace(1) %a, i64 440
  store atomic i32 %v106, ptr addrspace(1) %p106 unordered, align 4
  %p107 = getelementptr i8, ptr addrspace(1) %a, i64 444
  store atomic i32 %v107, ptr addrspace(1) %p107 unordered, align 4
  %p108 = getelementptr i8, ptr addrspace(1) %a, i64 448
  store atomic i32 %v108, ptr addrspace(1) %p108 unordered, align 4
  %p109 = getelementptr i8, ptr addrspace(1) %a, i64 452
  store atomic i32 %v109, ptr addrspace(1) %p109 unordered, align 4
  %p110 = getelementptr i8, ptr addrspace(1) %a, i64 456
  store atomic i32 %v110, ptr addrspace(1) %p110 unordered, align 4
  %p111 = getelementptr i8, ptr addrspace(1) %a, i64 460
  store atomic i32 %v111, ptr addrspace(1) %p111 unordered, align 4
  %p112 = getelementptr i8, ptr addrspace(1) %a, i64 464
  store atomic i32 %v112, ptr addrspace(1) %p112 unordered, align 4
  %p113 = getelementptr i8, ptr addrspace(1) %a, i64 468
  store atomic i32 %v113, ptr addrspace(1) %p113 unordered, align 4
  %p114 = getelementptr i8, ptr addrspace(1) %a, i64 472
  store atomic i32 %v114, ptr addrspace(1) %p114 unordered, align 4
  %p115 = getelementptr i8, ptr addrspace(1) %a, i64 476
  store atomic i32 %v115, ptr addrspace(1) %p115 unordered, align 4
  %p116 = getelementptr i8, ptr addrspace(1) %a, i64 480
  store atomic i32 %v116, ptr addrspace(1) %p116 unordered, align 4
  %p117 = getelementptr i8, ptr addrspace(1) %a, i64 484
  store atomic i32 %v117, ptr addrspace(1) %p117 unordered, align 4
  %p118 = getelementptr i8, ptr addrspace(1) %a, i64 488
  store atomic i32 %v118, ptr addrspace(1) %p118 unordered, align 4
  %p119 = getelementptr i8, ptr addrspace(1) %a, i64 492
  store atomic i32 %v119, ptr addrspace(1) %p119 unordered, align 4
  %p120 = getelementptr i8, ptr addrspace(1) %a, i64 496
  store atomic i32 %v120, ptr addrspace(1) %p120 unordered, align 4
  %p121 = getelementptr i8, ptr addrspace(1) %a, i64 500
  store atomic i32 %v121, ptr addrspace(1) %p121 unordered, align 4
  %p122 = getelementptr i8, ptr addrspace(1) %a, i64 504
  store atomic i32 %v122, ptr addrspace(1) %p122 unordered, align 4
  %p123 = getelementptr i8, ptr addrspace(1) %a, i64 508
  store atomic i32 %v123, ptr addrspace(1) %p123 unordered, align 4
  %p124 = getelementptr i8, ptr addrspace(1) %a, i64 512
  store atomic i32 %v124, ptr addrspace(1) %p124 unordered, align 4
  %p125 = getelementptr i8, ptr addrspace(1) %a, i64 516
  store atomic i32 %v125, ptr addrspace(1) %p125 unordered, align 4
  %p126 = getelementptr i8, ptr addrspace(1) %a, i64 520
  store atomic i32 %v126, ptr addrspace(1) %p126 unordered, align 4
  %p127 = getelementptr i8, ptr addrspace(1) %a, i64 524
  store atomic i32 %v127, ptr addrspace(1) %p127 unordered, align 4
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 128, i32 %seed, i32 10)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}

; CHECK-LABEL: @char22_from_int(
; CHECK: and <4 x i32>
; CHECK-COUNT-6: mul <4 x i32>
; CHECK: ret i32
define i32 @char22_from_int(i32 %v0, i32 %v1, i32 %v2, i32 %v3, i32 %v4, i32 %v5, i32 %v6, i32 %v7, i32 %v8, i32 %v9, i32 %v10, i32 %v11, i32 %v12, i32 %v13, i32 %v14, i32 %v15, i32 %v16, i32 %v17, i32 %v18, i32 %v19, i32 %v20, i32 %v21, i32 %seed) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 22, i32 64, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %c0 = trunc i32 %v0 to i16
  %c1 = trunc i32 %v1 to i16
  %c2 = trunc i32 %v2 to i16
  %c3 = trunc i32 %v3 to i16
  %c4 = trunc i32 %v4 to i16
  %c5 = trunc i32 %v5 to i16
  %c6 = trunc i32 %v6 to i16
  %c7 = trunc i32 %v7 to i16
  %c8 = trunc i32 %v8 to i16
  %c9 = trunc i32 %v9 to i16
  %c10 = trunc i32 %v10 to i16
  %c11 = trunc i32 %v11 to i16
  %c12 = trunc i32 %v12 to i16
  %c13 = trunc i32 %v13 to i16
  %c14 = trunc i32 %v14 to i16
  %c15 = trunc i32 %v15 to i16
  %c16 = trunc i32 %v16 to i16
  %c17 = trunc i32 %v17 to i16
  %c18 = trunc i32 %v18 to i16
  %c19 = trunc i32 %v19 to i16
  %c20 = trunc i32 %v20 to i16
  %c21 = trunc i32 %v21 to i16
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i16 %c0, ptr addrspace(1) %p0 unordered, align 2
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 18
  store atomic i16 %c1, ptr addrspace(1) %p1 unordered, align 2
  %p2 = getelementptr i8, ptr addrspace(1) %a, i64 20
  store atomic i16 %c2, ptr addrspace(1) %p2 unordered, align 2
  %p3 = getelementptr i8, ptr addrspace(1) %a, i64 22
  store atomic i16 %c3, ptr addrspace(1) %p3 unordered, align 2
  %p4 = getelementptr i8, ptr addrspace(1) %a, i64 24
  store atomic i16 %c4, ptr addrspace(1) %p4 unordered, align 2
  %p5 = getelementptr i8, ptr addrspace(1) %a, i64 26
  store atomic i16 %c5, ptr addrspace(1) %p5 unordered, align 2
  %p6 = getelementptr i8, ptr addrspace(1) %a, i64 28
  store atomic i16 %c6, ptr addrspace(1) %p6 unordered, align 2
  %p7 = getelementptr i8, ptr addrspace(1) %a, i64 30
  store atomic i16 %c7, ptr addrspace(1) %p7 unordered, align 2
  %p8 = getelementptr i8, ptr addrspace(1) %a, i64 32
  store atomic i16 %c8, ptr addrspace(1) %p8 unordered, align 2
  %p9 = getelementptr i8, ptr addrspace(1) %a, i64 34
  store atomic i16 %c9, ptr addrspace(1) %p9 unordered, align 2
  %p10 = getelementptr i8, ptr addrspace(1) %a, i64 36
  store atomic i16 %c10, ptr addrspace(1) %p10 unordered, align 2
  %p11 = getelementptr i8, ptr addrspace(1) %a, i64 38
  store atomic i16 %c11, ptr addrspace(1) %p11 unordered, align 2
  %p12 = getelementptr i8, ptr addrspace(1) %a, i64 40
  store atomic i16 %c12, ptr addrspace(1) %p12 unordered, align 2
  %p13 = getelementptr i8, ptr addrspace(1) %a, i64 42
  store atomic i16 %c13, ptr addrspace(1) %p13 unordered, align 2
  %p14 = getelementptr i8, ptr addrspace(1) %a, i64 44
  store atomic i16 %c14, ptr addrspace(1) %p14 unordered, align 2
  %p15 = getelementptr i8, ptr addrspace(1) %a, i64 46
  store atomic i16 %c15, ptr addrspace(1) %p15 unordered, align 2
  %p16 = getelementptr i8, ptr addrspace(1) %a, i64 48
  store atomic i16 %c16, ptr addrspace(1) %p16 unordered, align 2
  %p17 = getelementptr i8, ptr addrspace(1) %a, i64 50
  store atomic i16 %c17, ptr addrspace(1) %p17 unordered, align 2
  %p18 = getelementptr i8, ptr addrspace(1) %a, i64 52
  store atomic i16 %c18, ptr addrspace(1) %p18 unordered, align 2
  %p19 = getelementptr i8, ptr addrspace(1) %a, i64 54
  store atomic i16 %c19, ptr addrspace(1) %p19 unordered, align 2
  %p20 = getelementptr i8, ptr addrspace(1) %a, i64 56
  store atomic i16 %c20, ptr addrspace(1) %p20 unordered, align 2
  %p21 = getelementptr i8, ptr addrspace(1) %a, i64 58
  store atomic i16 %c21, ptr addrspace(1) %p21 unordered, align 2
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 22, i32 %seed, i32 5)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
