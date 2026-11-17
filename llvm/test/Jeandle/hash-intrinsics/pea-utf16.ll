; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform' -jeandle-vm-callback-log=%S/Inputs/layout.cblog -verify-each %s | FileCheck %s --check-prefixes=CHECK,LE
; RUN: sed 's/"e-p:/"E-p:/' %s > %t.be.ll
; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform' -jeandle-vm-callback-log=%S/Inputs/layout.cblog -verify-each %t.be.ll | FileCheck %s --check-prefixes=CHECK,BE
;
; Dynamic native-endian UTF16 supports separate byte cells and packed groups.
; A later unreadable cell must leave no speculative extraction effects.
target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
@arrayOopDesc.base_offset_in_bytes.int = constant i32 16
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @jeandle.vectorized_hashcode(ptr addrspace(1), i32, i32, i32, i32)
declare i32 @__gxx_personality_v0(...)
declare void @observe(ptr addrspace(1))

; CHECK-LABEL: @independent_bytes(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; LE: %[[LOW:.*]] = zext i8 %first to i32
; LE: %[[HIGH:.*]] = zext i8 %second to i32
; BE: %[[LOW:.*]] = zext i8 %second to i32
; BE: %[[HIGH:.*]] = zext i8 %first to i32
; CHECK: %[[SHIFT:.*]] = shl i32 %[[HIGH]], 8
; CHECK: %[[WORD:.*]] = or i32 %[[LOW]], %[[SHIFT]]
; CHECK: %[[M:.*]] = mul i32 %seed, 31
; CHECK: %[[HASH:.*]] = add i32 %[[M]], %[[WORD]]
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: ret i32 %[[HASH]]
define i32 @independent_bytes(i8 %first, i8 %second, i32 %seed) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 18
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 19
  store atomic i8 %first, ptr addrspace(1) %p0 unordered, align 1
  store atomic i8 %second, ptr addrspace(1) %p1 unordered, align 1
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 1, i32 1, i32 %seed, i32 5)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @packed_word(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: %[[WORD:.*]] = zext i16 %word to i32
; CHECK: ret i32 %[[WORD]]
define i32 @packed_word(i16 %word) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i16 %word, ptr addrspace(1) %p0 unordered, align 2
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 1, i32 0, i32 5)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @packed_subword(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; LE: %[[SHIFT:.*]] = lshr i32 %packed, 16
; LE: %[[WORD:.*]] = trunc i32 %[[SHIFT]] to i16
; BE: %[[WORD:.*]] = trunc i32 %packed to i16
; CHECK: %[[WIDE:.*]] = zext i16 %[[WORD]] to i32
; CHECK: ret i32 %[[WIDE]]
define i32 @packed_subword(i32 %packed) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %packed, ptr addrspace(1) %p0 unordered, align 4
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 1, i32 1, i32 0, i32 5)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @late_unreadable(
; CHECK: @jeandle.new_array
; CHECK-NOT: vhc.
; CHECK-NOT: string.cell
; CHECK: call i32 @jeandle.vectorized_hashcode
; CHECK: ret i32 %r
define i32 @late_unreadable(i32 %packed) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 6, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 20
  store atomic i32 %packed, ptr addrspace(1) %p0 unordered, align 4
  store atomic i16 undef, ptr addrspace(1) %p1 unordered, align 2
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 3, i32 0, i32 5)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @unsupported_layout(
; CHECK: @jeandle.new_array
; CHECK: call i32 @jeandle.vectorized_hashcode
; CHECK: ret i32 %r
define i32 @unsupported_layout(i32 %word) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %word, ptr addrspace(1) %p0 unordered, align 4
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 1, i32 0, i32 5)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The hash feeds a later byte store. Escaping preserves the original array
; identity and replays both input cells and the scalar hash-derived cell.
; CHECK-LABEL: @escape_replay(
; CHECK: %[[ARRAY:.*]] = {{call|invoke}} hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: %[[HASH:.*]] = or i32
; CHECK: %[[BYTE:.*]] = trunc i32 %[[HASH]] to i8
; CHECK-DAG: store atomic i8 %first,
; CHECK-DAG: store atomic i8 %second,
; CHECK-DAG: store atomic i8 %[[BYTE]],
; CHECK: call void @observe(ptr addrspace(1) %[[ARRAY]])
; CHECK-NOT: @jeandle.vectorized_hashcode
; CHECK: ret i32 %[[HASH]]
define i32 @escape_replay(i8 %first, i8 %second) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 17
  %p2 = getelementptr i8, ptr addrspace(1) %a, i64 18
  store atomic i8 %first, ptr addrspace(1) %p0 unordered, align 1
  store atomic i8 %second, ptr addrspace(1) %p1 unordered, align 1
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 1, i32 0, i32 5)
  %byte = trunc i32 %r to i8
  store atomic i8 %byte, ptr addrspace(1) %p2 unordered, align 1
  call void @observe(ptr addrspace(1) %a)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}
