; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/../string-intrinsics/Inputs/layout.cblog -verify-each %s | FileCheck %s --check-prefixes=CHECK,LE
; RUN: sed 's/e-p:64/E-p:64/;s/i64 16 ; low-byte/i64 17 ; low-byte/' %s | opt -S -passes='require<partial-escape-analysis>,partial-escape-transform,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/../string-intrinsics/Inputs/layout.cblog -verify-each | FileCheck %s --check-prefixes=CHECK,BE

target datalayout = "e-p:64:64-p1:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.encode_array(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1, i1)
declare i32 @personality(...)

; Direct PEA input retains the opaque JavaOp. It must consume symbolic byte
; pairs and packed words without expanding a 64-way control-flow chain.
; A dynamic failure at character 32 preserves the destination suffix.
; CHECK-LABEL: define i32 @encode64(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.encode_array
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: select i1 %fail
; CHECK-NOT: call
; CHECK: ret i32

define i32 @encode64(i8 %low, i1 %fail) gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 128, i32 144, i32 16, i32 100, i1 false, i1 false) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 68, i32 88, i32 16, i32 100, i1 false, i1 false) to label %body unwind label %u
body:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 16 ; low-byte
  store atomic i8 %low, ptr addrspace(1) %sp unordered, align 1
  %wide = zext i8 %low to i16
  %maybe = select i1 %fail, i16 256, i16 %wide
  %middle = getelementptr i8, ptr addrspace(1) %src, i64 80
  store atomic i16 %maybe, ptr addrspace(1) %middle unordered, align 2
  %last = getelementptr i8, ptr addrspace(1) %src, i64 142
  store atomic i16 %wide, ptr addrspace(1) %last unordered, align 2
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 48
  store atomic i32 117901063, ptr addrspace(1) %dp unordered, align 4
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 64, i1 true, i1 false)
  %cell = load atomic i32, ptr addrspace(1) %dp unordered, align 4
  %v = and i32 %cell, 255
  %result = add i32 %v, %r
  ret i32 %result
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Unknown characters are represented by guarded SSA values. The first failing
; character returns zero, leaves the packed destination intact, and writes no
; later byte. This also exercises destination offsets inside a packed group.
; CHECK-LABEL: define i32 @unknown_ascii(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.encode_array
; CHECK: icmp ult i16 %value, 128
; CHECK: select
; CHECK: ret i32

define i32 @unknown_ascii(i16 %value) gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 24, i32 16, i32 100, i1 false, i1 false) to label %body unwind label %u
body:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 16
  store atomic i16 %value, ptr addrspace(1) %sp unordered, align 2
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 16
  store atomic i32 117901063, ptr addrspace(1) %dp unordered, align 4
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 1, i32 2, i1 false, i1 true)
  %cell = load atomic i32, ptr addrspace(1) %dp unordered, align 4
  %result = add i32 %cell, %r
  ret i32 %result
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
!java-method-compilation = !{}

; A constant failure after a symbolic character ends the write transaction
; regardless of whether the symbolic character has already failed.
; CHECK-LABEL: define i32 @unknown_then_invalid(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.encode_array
; CHECK: icmp ult i16 %value, 128
; CHECK: select
; CHECK: ret i32
define i32 @unknown_then_invalid(i16 %value) gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 24, i32 16, i32 100, i1 false, i1 false) to label %body unwind label %u
body:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 16
  store atomic i16 %value, ptr addrspace(1) %sp unordered, align 2
  %s1 = getelementptr i8, ptr addrspace(1) %src, i64 18
  store atomic i16 256, ptr addrspace(1) %s1 unordered, align 2
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 16
  store atomic i32 117901063, ptr addrspace(1) %dp unordered, align 4
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 1, i32 2, i1 false, i1 true)
  %cell = load atomic i32, ptr addrspace(1) %dp unordered, align 4
  %result = add i32 %cell, %r
  ret i32 %result
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

declare hotspotcc i32 @jeandle.string_compress(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)

; The symbolic suffix is never read after the known failing second word.
; The first byte is committed, and all other packed destination bytes survive.
; CHECK-LABEL: define i32 @known_bad_after_prefix_bytes(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.string_compress
; LE: ret i32 117901121
; BE: ret i32 1090979591

define i32 @known_bad_after_prefix_bytes(i8 %unread) gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 6, i32 24, i32 16, i32 100, i1 false, i1 false) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 24, i32 16, i32 100, i1 false, i1 false) to label %body unwind label %u
body:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 16
  %s1 = getelementptr i8, ptr addrspace(1) %src, i64 18
  %s2 = getelementptr i8, ptr addrspace(1) %src, i64 20
  store atomic i16 65, ptr addrspace(1) %sp unordered, align 2
  store atomic i16 256, ptr addrspace(1) %s1 unordered, align 2
  store atomic i8 %unread, ptr addrspace(1) %s2 unordered, align 1
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 16
  store atomic i32 117901063, ptr addrspace(1) %dp unordered, align 4
  %r = call hotspotcc i32 @jeandle.string_compress(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 3, i1 true)
  %cell = load atomic i32, ptr addrspace(1) %dp unordered, align 4
  %result = add i32 %cell, %r
  ret i32 %result
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
