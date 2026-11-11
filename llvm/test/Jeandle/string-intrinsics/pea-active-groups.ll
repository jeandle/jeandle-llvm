; RUN: opt -S -verify-each -passes='require<partial-escape-analysis>,partial-escape-transform,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/Inputs/getchar-byte-cells.cblog %s | FileCheck %s --check-prefixes=CHECK,LE
; RUN: sed 's/target datalayout = "e-/target datalayout = "E-/' %s | opt -S -verify-each -passes='require<partial-escape-analysis>,partial-escape-transform,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/Inputs/getchar-byte-cells.cblog | FileCheck %s --check-prefixes=CHECK,BE

target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1), i32) nounwind memory(read)
declare void @jeandle.string_copy_utf16(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)
declare i32 @jeandle.string_compress(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)
declare i32 @__gxx_personality_v0(...)
; CHECK-LABEL: @default_low_nonzero_high(
; CHECK-NOT: @jeandle.new_array
; LE: ret i16 256
; BE: ret i16 1
define i16 @default_low_nonzero_high() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %array = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %unwind
work:
  %high = getelementptr i8, ptr addrspace(1) %array, i64 17
  store atomic i8 1, ptr addrspace(1) %high unordered, align 1
  %result = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %array, i32 0)
  ret i16 %result
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
; CHECK-LABEL: @overwrite_packed_tail_with_utf16(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.string_copy_utf16
; LE: ret i32 2005414724
; BE: ret i32 287471496
define i32 @overwrite_packed_tail_with_utf16() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %source = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 1, i32 24, i32 16, i32 100, i1 false, i1 false) to label %allocate unwind label %unwind
allocate:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %unwind
work:
  %source_cell = getelementptr i8, ptr addrspace(1) %source, i64 16
  store atomic i16 30600, ptr addrspace(1) %source_cell unordered, align 2
  %dest_word = getelementptr i8, ptr addrspace(1) %dest, i64 16
  store atomic i32 287454020, ptr addrspace(1) %dest_word unordered, align 4
  call void @jeandle.string_copy_utf16(ptr addrspace(1) %source, i32 0, ptr addrspace(1) %dest, i32 1, i32 1, i1 false)
  %result = load atomic i32, ptr addrspace(1) %dest_word unordered, align 4
  ret i32 %result
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
; CHECK-LABEL: @overwrite_packed_head_with_compress(
; CHECK: @jeandle.new_array
; CHECK-NOT: @jeandle.string_compress
; LE: store atomic i16 4417
; BE: store atomic i16 16674
; CHECK: load atomic i8
define i8 @overwrite_packed_head_with_compress() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %source = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 1, i32 24, i32 16, i32 100, i1 false, i1 false) to label %allocate unwind label %unwind
allocate:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %unwind
work:
  %source_cell = getelementptr i8, ptr addrspace(1) %source, i64 16
  store atomic i16 65, ptr addrspace(1) %source_cell unordered, align 2
  %dest_word = getelementptr i8, ptr addrspace(1) %dest, i64 16
  store atomic i16 4386, ptr addrspace(1) %dest_word unordered, align 2
  %count = call i32 @jeandle.string_compress(ptr addrspace(1) %source, i32 0, ptr addrspace(1) %dest, i32 0, i32 1, i1 false)
  %tail = getelementptr i8, ptr addrspace(1) %dest, i64 17
  %result = load atomic i8, ptr addrspace(1) %tail unordered, align 1
  ret i8 %result
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
!java-method-compilation = !{}

; CHECK-LABEL: @packed_getchar(
; CHECK-NOT: @jeandle.new_array
; LE: lshr i32 %bits, 16
; CHECK: trunc{{( nuw)?}} i32
; CHECK: ret i16
 define i16 @packed_getchar(i32 %bits) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %array = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %unwind
work:
  %word = getelementptr i8, ptr addrspace(1) %array, i64 16
  store atomic i32 %bits, ptr addrspace(1) %word unordered, align 4
  %result = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %array, i32 1)
  ret i16 %result
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A conversion that cannot fold its whole source must retain the initial
; destination group and the original conversion, with no partial state commit.
; CHECK-LABEL: @transaction_bail(
; CHECK: store atomic i32 287454020
; CHECK: call i32 @jeandle.string_compress
; CHECK: load atomic i32
 define i32 @transaction_bail(i16 %unknown) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %source = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %allocate unwind label %unwind
allocate:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %unwind
work:
  %s0 = getelementptr i8, ptr addrspace(1) %source, i64 16
  %s1 = getelementptr i8, ptr addrspace(1) %source, i64 18
  store atomic i16 65, ptr addrspace(1) %s0 unordered, align 2
  store atomic i16 %unknown, ptr addrspace(1) %s1 unordered, align 2
  %word = getelementptr i8, ptr addrspace(1) %dest, i64 16
  store atomic i32 287454020, ptr addrspace(1) %word unordered, align 4
  %count = call i32 @jeandle.string_compress(ptr addrspace(1) %source, i32 0, ptr addrspace(1) %dest, i32 0, i32 2, i1 false)
  %result = load atomic i32, ptr addrspace(1) %word unordered, align 4
  ret i32 %result
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @symbolic_packed_tail(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.string_copy_utf16
; LE: and i32 %bits, 65535
; BE: and i32 %bits, -65536
; CHECK: or{{( disjoint)?}} i32
; CHECK: ret i32
define i32 @symbolic_packed_tail(i32 %bits) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %source = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 1, i32 24, i32 16, i32 100, i1 false, i1 false) to label %allocate unwind label %unwind
allocate:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %unwind
work:
  %source_cell = getelementptr i8, ptr addrspace(1) %source, i64 16
  store atomic i16 30600, ptr addrspace(1) %source_cell unordered, align 2
  %dest_word = getelementptr i8, ptr addrspace(1) %dest, i64 16
  store atomic i32 %bits, ptr addrspace(1) %dest_word unordered, align 4
  call void @jeandle.string_copy_utf16(ptr addrspace(1) %source, i32 0, ptr addrspace(1) %dest, i32 1, i32 1, i1 false)
  %result = load atomic i32, ptr addrspace(1) %dest_word unordered, align 4
  ret i32 %result
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Packed char source entries participate in constant String consumers.
; CHECK-LABEL: @compress_packed_source(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.string_compress
; CHECK: ret i16 16961
 define i16 @compress_packed_source() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %source = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %allocate unwind label %unwind
allocate:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %unwind
work:
  %word = getelementptr i8, ptr addrspace(1) %source, i64 16
  store atomic i32 4325441, ptr addrspace(1) %word unordered, align 4
  %count = call i32 @jeandle.string_compress(ptr addrspace(1) %source, i32 0, ptr addrspace(1) %dest, i32 0, i32 2, i1 false)
  %result = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %dest, i32 0)
  ret i16 %result
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Compression writes its valid prefix even when a later char is not Latin1.
; CHECK-LABEL: @compress_packed_prefix(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.string_compress
; LE: ret i16 4417
; BE: ret i16 16674
 define i16 @compress_packed_prefix() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %source = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %allocate unwind label %unwind
allocate:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %unwind
work:
  %s0 = getelementptr i8, ptr addrspace(1) %source, i64 16
  %s1 = getelementptr i8, ptr addrspace(1) %source, i64 18
  store atomic i16 65, ptr addrspace(1) %s0 unordered, align 2
  store atomic i16 256, ptr addrspace(1) %s1 unordered, align 2
  %word = getelementptr i8, ptr addrspace(1) %dest, i64 16
  store atomic i16 4386, ptr addrspace(1) %word unordered, align 2
  %count = call i32 @jeandle.string_compress(ptr addrspace(1) %source, i32 0, ptr addrspace(1) %dest, i32 0, i32 2, i1 false)
  %result = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %dest, i32 0)
  %count16 = trunc i32 %count to i16
  %answer = add i16 %result, %count16
  ret i16 %answer
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A later unsupported partial group must not commit an earlier group update.
; CHECK-LABEL: @destination_transaction_bail(
; CHECK: store atomic i16 4386
; CHECK: call i32 @jeandle.string_compress
 define i16 @destination_transaction_bail() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %source = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 3, i32 24, i32 16, i32 100, i1 false, i1 false) to label %allocate unwind label %unwind
allocate:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 6, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %unwind
work:
  %s0 = getelementptr i8, ptr addrspace(1) %source, i64 16
  %s1 = getelementptr i8, ptr addrspace(1) %source, i64 18
  %s2 = getelementptr i8, ptr addrspace(1) %source, i64 20
  store atomic i16 65, ptr addrspace(1) %s0 unordered, align 2
  store atomic i16 66, ptr addrspace(1) %s1 unordered, align 2
  store atomic i16 67, ptr addrspace(1) %s2 unordered, align 2
  %head = getelementptr i8, ptr addrspace(1) %dest, i64 16
  %tail = getelementptr i8, ptr addrspace(1) %dest, i64 18
  store atomic i16 4386, ptr addrspace(1) %head unordered, align 2
  store atomic i32 poison, ptr addrspace(1) %tail unordered, align 2
  %count = call i32 @jeandle.string_compress(ptr addrspace(1) %source, i32 0, ptr addrspace(1) %dest, i32 0, i32 3, i1 false)
  %result = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %dest, i32 0)
  ret i16 %result
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
