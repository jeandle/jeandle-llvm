; RUN: opt -S -passes='character-intrinsic-specialization,instcombine,simplifycfg,loop-simplify,break-crit-edges,loop(loop-rotate,indvars,loop-deletion),pre-pea-allocation-unroll-hints,loop-unroll<O3;no-partial;no-runtime;no-upperbound;full-unroll-max=128>,instcombine,gvn,simplifycfg,require<partial-escape-analysis>,partial-escape-transform,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/../string-intrinsics/Inputs/layout.cblog -verify-each %s | FileCheck %s
;
; Local encoding uses the same bounded full-unroll cluster as ordinary Java
; loops. A runtime byte keeps the conversion live while proving that every
; source character is encodable. Both allocations must disappear.

target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
@arrayOopDesc.base_offset_in_bytes.char = constant i32 16
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @personality(...)
declare hotspotcc i32 @jeandle.encode_array(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1, i1)

; CHECK-LABEL: @chars8(
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: zext i8 %value to i32
; CHECK: add {{.*}}i32 {{.*}}, 8
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: ret i32
define i32 @chars8(i8 %value) gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 8, i32 32, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 8, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 30
  %wide = zext i8 %value to i16
  store atomic i16 %wide, ptr addrspace(1) %sp unordered, align 2
  %count = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 8, i1 false, i1 false)
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 23
  %cell = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  %result = zext i8 %cell to i32
  %sum = add i32 %result, %count
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @chars9(
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: zext i8 %value to i32
; CHECK: add {{.*}}i32 {{.*}}, 9
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: ret i32
define i32 @chars9(i8 %value) gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 9, i32 34, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 9, i32 25, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 32
  %wide = zext i8 %value to i16
  store atomic i16 %wide, ptr addrspace(1) %sp unordered, align 2
  %count = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 9, i1 false, i1 false)
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 24
  %cell = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  %result = zext i8 %cell to i32
  %sum = add i32 %result, %count
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @chars16(
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: zext i8 %value to i32
; CHECK: add {{.*}}i32 {{.*}}, 16
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: ret i32
define i32 @chars16(i8 %value) gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 16, i32 48, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 16, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 46
  %wide = zext i8 %value to i16
  store atomic i16 %wide, ptr addrspace(1) %sp unordered, align 2
  %count = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 16, i1 false, i1 false)
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 31
  %cell = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  %result = zext i8 %cell to i32
  %sum = add i32 %result, %count
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @chars17(
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: zext i8 %value to i32
; CHECK: add {{.*}}i32 {{.*}}, 17
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: ret i32
define i32 @chars17(i8 %value) gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 17, i32 50, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 17, i32 33, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 48
  %wide = zext i8 %value to i16
  store atomic i16 %wide, ptr addrspace(1) %sp unordered, align 2
  %count = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 false, i1 false)
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 32
  %cell = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  %result = zext i8 %cell to i32
  %sum = add i32 %result, %count
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @chars64(
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: zext i8 %value to i32
; CHECK: add {{.*}}i32 {{.*}}, 64
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: ret i32
define i32 @chars64(i8 %value) gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 64, i32 144, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 64, i32 80, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 142
  %wide = zext i8 %value to i16
  store atomic i16 %wide, ptr addrspace(1) %sp unordered, align 2
  %count = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 64, i1 false, i1 false)
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 79
  %cell = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  %result = zext i8 %cell to i32
  %sum = add i32 %result, %count
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @utf168(
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: zext i8 %value to i32
; CHECK: add {{.*}}i32 {{.*}}, 8
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: ret i32
define i32 @utf168(i8 %value) gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 16, i32 32, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 8, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 30
  store atomic i8 %value, ptr addrspace(1) %sp unordered, align 1
  %count = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 8, i1 true, i1 false)
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 23
  %cell = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  %result = zext i8 %cell to i32
  %sum = add i32 %result, %count
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @utf169(
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: zext i8 %value to i32
; CHECK: add {{.*}}i32 {{.*}}, 9
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: ret i32
define i32 @utf169(i8 %value) gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 18, i32 34, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 9, i32 25, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 32
  store atomic i8 %value, ptr addrspace(1) %sp unordered, align 1
  %count = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 9, i1 true, i1 false)
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 24
  %cell = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  %result = zext i8 %cell to i32
  %sum = add i32 %result, %count
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @utf1616(
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: zext i8 %value to i32
; CHECK: add {{.*}}i32 {{.*}}, 16
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: ret i32
define i32 @utf1616(i8 %value) gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 32, i32 48, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 16, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 46
  store atomic i8 %value, ptr addrspace(1) %sp unordered, align 1
  %count = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 16, i1 true, i1 false)
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 31
  %cell = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  %result = zext i8 %cell to i32
  %sum = add i32 %result, %count
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @utf1617(
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: zext i8 %value to i32
; CHECK: add {{.*}}i32 {{.*}}, 17
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: ret i32
define i32 @utf1617(i8 %value) gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 34, i32 50, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 17, i32 33, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 48
  store atomic i8 %value, ptr addrspace(1) %sp unordered, align 1
  %count = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 17, i1 true, i1 false)
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 32
  %cell = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  %result = zext i8 %cell to i32
  %sum = add i32 %result, %count
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @utf1632(
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: zext i8 %value to i32
; CHECK: add {{.*}}i32 {{.*}}, 32
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: ret i32
define i32 @utf1632(i8 %value) gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 64, i32 80, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 32, i32 48, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 78
  store atomic i8 %value, ptr addrspace(1) %sp unordered, align 1
  %count = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 32, i1 true, i1 false)
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 47
  %cell = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  %result = zext i8 %cell to i32
  %sum = add i32 %result, %count
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The raw byte-pair access cost exceeds the budget at 64. Keep the native
; operation rather than retaining a scalar loop after unsuccessful expansion.
; CHECK-LABEL: @utf1664(
; CHECK: @jeandle.new_array
; CHECK: call hotspotcc i32 @jeandle.encode_array
; CHECK: ret i32
define i32 @utf1664(i8 %value) gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 128, i32 144, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 64, i32 80, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 142
  store atomic i8 %value, ptr addrspace(1) %sp unordered, align 1
  %count = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 64, i1 true, i1 false)
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 79
  %cell = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  %result = zext i8 %cell to i32
  %sum = add i32 %result, %count
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @charsPartial17(
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: ret i32 81301
define i32 @charsPartial17() gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 20, i32 56, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 20, i32 36, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %first = getelementptr i8, ptr addrspace(1) %src, i64 18
  store atomic i16 65, ptr addrspace(1) %first unordered, align 2
  %bad = getelementptr i8, ptr addrspace(1) %src, i64 34
  store atomic i16 256, ptr addrspace(1) %bad unordered, align 2
  %d0 = getelementptr i8, ptr addrspace(1) %dst, i64 16
  store atomic i8 7, ptr addrspace(1) %d0 unordered, align 1
  %d1 = getelementptr i8, ptr addrspace(1) %dst, i64 17
  store atomic i8 7, ptr addrspace(1) %d1 unordered, align 1
  %d2 = getelementptr i8, ptr addrspace(1) %dst, i64 18
  store atomic i8 7, ptr addrspace(1) %d2 unordered, align 1
  %d3 = getelementptr i8, ptr addrspace(1) %dst, i64 19
  store atomic i8 7, ptr addrspace(1) %d3 unordered, align 1
  %d4 = getelementptr i8, ptr addrspace(1) %dst, i64 20
  store atomic i8 7, ptr addrspace(1) %d4 unordered, align 1
  %d5 = getelementptr i8, ptr addrspace(1) %dst, i64 21
  store atomic i8 7, ptr addrspace(1) %d5 unordered, align 1
  %d6 = getelementptr i8, ptr addrspace(1) %dst, i64 22
  store atomic i8 7, ptr addrspace(1) %d6 unordered, align 1
  %d7 = getelementptr i8, ptr addrspace(1) %dst, i64 23
  store atomic i8 7, ptr addrspace(1) %d7 unordered, align 1
  %d8 = getelementptr i8, ptr addrspace(1) %dst, i64 24
  store atomic i8 7, ptr addrspace(1) %d8 unordered, align 1
  %d9 = getelementptr i8, ptr addrspace(1) %dst, i64 25
  store atomic i8 7, ptr addrspace(1) %d9 unordered, align 1
  %d10 = getelementptr i8, ptr addrspace(1) %dst, i64 26
  store atomic i8 7, ptr addrspace(1) %d10 unordered, align 1
  %d11 = getelementptr i8, ptr addrspace(1) %dst, i64 27
  store atomic i8 7, ptr addrspace(1) %d11 unordered, align 1
  %d12 = getelementptr i8, ptr addrspace(1) %dst, i64 28
  store atomic i8 7, ptr addrspace(1) %d12 unordered, align 1
  %d13 = getelementptr i8, ptr addrspace(1) %dst, i64 29
  store atomic i8 7, ptr addrspace(1) %d13 unordered, align 1
  %d14 = getelementptr i8, ptr addrspace(1) %dst, i64 30
  store atomic i8 7, ptr addrspace(1) %d14 unordered, align 1
  %d15 = getelementptr i8, ptr addrspace(1) %dst, i64 31
  store atomic i8 7, ptr addrspace(1) %d15 unordered, align 1
  %d16 = getelementptr i8, ptr addrspace(1) %dst, i64 32
  store atomic i8 7, ptr addrspace(1) %d16 unordered, align 1
  %d17 = getelementptr i8, ptr addrspace(1) %dst, i64 33
  store atomic i8 7, ptr addrspace(1) %d17 unordered, align 1
  %d18 = getelementptr i8, ptr addrspace(1) %dst, i64 34
  store atomic i8 7, ptr addrspace(1) %d18 unordered, align 1
  %d19 = getelementptr i8, ptr addrspace(1) %dst, i64 35
  store atomic i8 7, ptr addrspace(1) %d19 unordered, align 1
  %count = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 17, i1 false, i1 false)
  %r0 = mul i32 %count, 10000
  %b0 = load atomic i8, ptr addrspace(1) %d0 unordered, align 1
  %v0 = zext i8 %b0 to i32
  %w0 = mul i32 %v0, 1
  %r1 = add i32 %r0, %w0
  %b1 = load atomic i8, ptr addrspace(1) %d1 unordered, align 1
  %v1 = zext i8 %b1 to i32
  %w1 = mul i32 %v1, 2
  %r2 = add i32 %r1, %w1
  %b2 = load atomic i8, ptr addrspace(1) %d2 unordered, align 1
  %v2 = zext i8 %b2 to i32
  %w2 = mul i32 %v2, 3
  %r3 = add i32 %r2, %w2
  %b3 = load atomic i8, ptr addrspace(1) %d3 unordered, align 1
  %v3 = zext i8 %b3 to i32
  %w3 = mul i32 %v3, 4
  %r4 = add i32 %r3, %w3
  %b4 = load atomic i8, ptr addrspace(1) %d4 unordered, align 1
  %v4 = zext i8 %b4 to i32
  %w4 = mul i32 %v4, 5
  %r5 = add i32 %r4, %w4
  %b5 = load atomic i8, ptr addrspace(1) %d5 unordered, align 1
  %v5 = zext i8 %b5 to i32
  %w5 = mul i32 %v5, 6
  %r6 = add i32 %r5, %w5
  %b6 = load atomic i8, ptr addrspace(1) %d6 unordered, align 1
  %v6 = zext i8 %b6 to i32
  %w6 = mul i32 %v6, 7
  %r7 = add i32 %r6, %w6
  %b7 = load atomic i8, ptr addrspace(1) %d7 unordered, align 1
  %v7 = zext i8 %b7 to i32
  %w7 = mul i32 %v7, 8
  %r8 = add i32 %r7, %w7
  %b8 = load atomic i8, ptr addrspace(1) %d8 unordered, align 1
  %v8 = zext i8 %b8 to i32
  %w8 = mul i32 %v8, 9
  %r9 = add i32 %r8, %w8
  %b9 = load atomic i8, ptr addrspace(1) %d9 unordered, align 1
  %v9 = zext i8 %b9 to i32
  %w9 = mul i32 %v9, 10
  %r10 = add i32 %r9, %w9
  %b10 = load atomic i8, ptr addrspace(1) %d10 unordered, align 1
  %v10 = zext i8 %b10 to i32
  %w10 = mul i32 %v10, 11
  %r11 = add i32 %r10, %w10
  %b11 = load atomic i8, ptr addrspace(1) %d11 unordered, align 1
  %v11 = zext i8 %b11 to i32
  %w11 = mul i32 %v11, 12
  %r12 = add i32 %r11, %w11
  %b12 = load atomic i8, ptr addrspace(1) %d12 unordered, align 1
  %v12 = zext i8 %b12 to i32
  %w12 = mul i32 %v12, 13
  %r13 = add i32 %r12, %w12
  %b13 = load atomic i8, ptr addrspace(1) %d13 unordered, align 1
  %v13 = zext i8 %b13 to i32
  %w13 = mul i32 %v13, 14
  %r14 = add i32 %r13, %w13
  %b14 = load atomic i8, ptr addrspace(1) %d14 unordered, align 1
  %v14 = zext i8 %b14 to i32
  %w14 = mul i32 %v14, 15
  %r15 = add i32 %r14, %w14
  %b15 = load atomic i8, ptr addrspace(1) %d15 unordered, align 1
  %v15 = zext i8 %b15 to i32
  %w15 = mul i32 %v15, 16
  %r16 = add i32 %r15, %w15
  %b16 = load atomic i8, ptr addrspace(1) %d16 unordered, align 1
  %v16 = zext i8 %b16 to i32
  %w16 = mul i32 %v16, 17
  %r17 = add i32 %r16, %w16
  %b17 = load atomic i8, ptr addrspace(1) %d17 unordered, align 1
  %v17 = zext i8 %b17 to i32
  %w17 = mul i32 %v17, 18
  %r18 = add i32 %r17, %w17
  %b18 = load atomic i8, ptr addrspace(1) %d18 unordered, align 1
  %v18 = zext i8 %b18 to i32
  %w18 = mul i32 %v18, 19
  %r19 = add i32 %r18, %w18
  %b19 = load atomic i8, ptr addrspace(1) %d19 unordered, align 1
  %v19 = zext i8 %b19 to i32
  %w19 = mul i32 %v19, 20
  %r20 = add i32 %r19, %w19
  ret i32 %r20
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @utf16Partial17(
; CHECK-NOT: call
; CHECK-NOT: invoke
; CHECK: ret i32 81301
define i32 @utf16Partial17() gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 40, i32 56, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 20, i32 36, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %first = getelementptr i8, ptr addrspace(1) %src, i64 18
  store atomic i8 65, ptr addrspace(1) %first unordered, align 1
  %bad = getelementptr i8, ptr addrspace(1) %src, i64 35
  store atomic i8 1, ptr addrspace(1) %bad unordered, align 1
  %d0 = getelementptr i8, ptr addrspace(1) %dst, i64 16
  store atomic i8 7, ptr addrspace(1) %d0 unordered, align 1
  %d1 = getelementptr i8, ptr addrspace(1) %dst, i64 17
  store atomic i8 7, ptr addrspace(1) %d1 unordered, align 1
  %d2 = getelementptr i8, ptr addrspace(1) %dst, i64 18
  store atomic i8 7, ptr addrspace(1) %d2 unordered, align 1
  %d3 = getelementptr i8, ptr addrspace(1) %dst, i64 19
  store atomic i8 7, ptr addrspace(1) %d3 unordered, align 1
  %d4 = getelementptr i8, ptr addrspace(1) %dst, i64 20
  store atomic i8 7, ptr addrspace(1) %d4 unordered, align 1
  %d5 = getelementptr i8, ptr addrspace(1) %dst, i64 21
  store atomic i8 7, ptr addrspace(1) %d5 unordered, align 1
  %d6 = getelementptr i8, ptr addrspace(1) %dst, i64 22
  store atomic i8 7, ptr addrspace(1) %d6 unordered, align 1
  %d7 = getelementptr i8, ptr addrspace(1) %dst, i64 23
  store atomic i8 7, ptr addrspace(1) %d7 unordered, align 1
  %d8 = getelementptr i8, ptr addrspace(1) %dst, i64 24
  store atomic i8 7, ptr addrspace(1) %d8 unordered, align 1
  %d9 = getelementptr i8, ptr addrspace(1) %dst, i64 25
  store atomic i8 7, ptr addrspace(1) %d9 unordered, align 1
  %d10 = getelementptr i8, ptr addrspace(1) %dst, i64 26
  store atomic i8 7, ptr addrspace(1) %d10 unordered, align 1
  %d11 = getelementptr i8, ptr addrspace(1) %dst, i64 27
  store atomic i8 7, ptr addrspace(1) %d11 unordered, align 1
  %d12 = getelementptr i8, ptr addrspace(1) %dst, i64 28
  store atomic i8 7, ptr addrspace(1) %d12 unordered, align 1
  %d13 = getelementptr i8, ptr addrspace(1) %dst, i64 29
  store atomic i8 7, ptr addrspace(1) %d13 unordered, align 1
  %d14 = getelementptr i8, ptr addrspace(1) %dst, i64 30
  store atomic i8 7, ptr addrspace(1) %d14 unordered, align 1
  %d15 = getelementptr i8, ptr addrspace(1) %dst, i64 31
  store atomic i8 7, ptr addrspace(1) %d15 unordered, align 1
  %d16 = getelementptr i8, ptr addrspace(1) %dst, i64 32
  store atomic i8 7, ptr addrspace(1) %d16 unordered, align 1
  %d17 = getelementptr i8, ptr addrspace(1) %dst, i64 33
  store atomic i8 7, ptr addrspace(1) %d17 unordered, align 1
  %d18 = getelementptr i8, ptr addrspace(1) %dst, i64 34
  store atomic i8 7, ptr addrspace(1) %d18 unordered, align 1
  %d19 = getelementptr i8, ptr addrspace(1) %dst, i64 35
  store atomic i8 7, ptr addrspace(1) %d19 unordered, align 1
  %count = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 17, i1 true, i1 false)
  %r0 = mul i32 %count, 10000
  %b0 = load atomic i8, ptr addrspace(1) %d0 unordered, align 1
  %v0 = zext i8 %b0 to i32
  %w0 = mul i32 %v0, 1
  %r1 = add i32 %r0, %w0
  %b1 = load atomic i8, ptr addrspace(1) %d1 unordered, align 1
  %v1 = zext i8 %b1 to i32
  %w1 = mul i32 %v1, 2
  %r2 = add i32 %r1, %w1
  %b2 = load atomic i8, ptr addrspace(1) %d2 unordered, align 1
  %v2 = zext i8 %b2 to i32
  %w2 = mul i32 %v2, 3
  %r3 = add i32 %r2, %w2
  %b3 = load atomic i8, ptr addrspace(1) %d3 unordered, align 1
  %v3 = zext i8 %b3 to i32
  %w3 = mul i32 %v3, 4
  %r4 = add i32 %r3, %w3
  %b4 = load atomic i8, ptr addrspace(1) %d4 unordered, align 1
  %v4 = zext i8 %b4 to i32
  %w4 = mul i32 %v4, 5
  %r5 = add i32 %r4, %w4
  %b5 = load atomic i8, ptr addrspace(1) %d5 unordered, align 1
  %v5 = zext i8 %b5 to i32
  %w5 = mul i32 %v5, 6
  %r6 = add i32 %r5, %w5
  %b6 = load atomic i8, ptr addrspace(1) %d6 unordered, align 1
  %v6 = zext i8 %b6 to i32
  %w6 = mul i32 %v6, 7
  %r7 = add i32 %r6, %w6
  %b7 = load atomic i8, ptr addrspace(1) %d7 unordered, align 1
  %v7 = zext i8 %b7 to i32
  %w7 = mul i32 %v7, 8
  %r8 = add i32 %r7, %w7
  %b8 = load atomic i8, ptr addrspace(1) %d8 unordered, align 1
  %v8 = zext i8 %b8 to i32
  %w8 = mul i32 %v8, 9
  %r9 = add i32 %r8, %w8
  %b9 = load atomic i8, ptr addrspace(1) %d9 unordered, align 1
  %v9 = zext i8 %b9 to i32
  %w9 = mul i32 %v9, 10
  %r10 = add i32 %r9, %w9
  %b10 = load atomic i8, ptr addrspace(1) %d10 unordered, align 1
  %v10 = zext i8 %b10 to i32
  %w10 = mul i32 %v10, 11
  %r11 = add i32 %r10, %w10
  %b11 = load atomic i8, ptr addrspace(1) %d11 unordered, align 1
  %v11 = zext i8 %b11 to i32
  %w11 = mul i32 %v11, 12
  %r12 = add i32 %r11, %w11
  %b12 = load atomic i8, ptr addrspace(1) %d12 unordered, align 1
  %v12 = zext i8 %b12 to i32
  %w12 = mul i32 %v12, 13
  %r13 = add i32 %r12, %w12
  %b13 = load atomic i8, ptr addrspace(1) %d13 unordered, align 1
  %v13 = zext i8 %b13 to i32
  %w13 = mul i32 %v13, 14
  %r14 = add i32 %r13, %w13
  %b14 = load atomic i8, ptr addrspace(1) %d14 unordered, align 1
  %v14 = zext i8 %b14 to i32
  %w14 = mul i32 %v14, 15
  %r15 = add i32 %r14, %w14
  %b15 = load atomic i8, ptr addrspace(1) %d15 unordered, align 1
  %v15 = zext i8 %b15 to i32
  %w15 = mul i32 %v15, 16
  %r16 = add i32 %r15, %w15
  %b16 = load atomic i8, ptr addrspace(1) %d16 unordered, align 1
  %v16 = zext i8 %b16 to i32
  %w16 = mul i32 %v16, 17
  %r17 = add i32 %r16, %w16
  %b17 = load atomic i8, ptr addrspace(1) %d17 unordered, align 1
  %v17 = zext i8 %b17 to i32
  %w17 = mul i32 %v17, 18
  %r18 = add i32 %r17, %w17
  %b18 = load atomic i8, ptr addrspace(1) %d18 unordered, align 1
  %v18 = zext i8 %b18 to i32
  %w18 = mul i32 %v18, 19
  %r19 = add i32 %r18, %w18
  %b19 = load atomic i8, ptr addrspace(1) %d19 unordered, align 1
  %v19 = zext i8 %b19 to i32
  %w19 = mul i32 %v19, 20
  %r20 = add i32 %r19, %w19
  ret i32 %r20
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}
