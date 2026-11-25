; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform' -jeandle-vm-callback-log=%S/../string-intrinsics/Inputs/layout.cblog -verify-each %s | FileCheck %s --check-prefix=RAW
; RUN: opt -S -passes='function(require<partial-escape-analysis>,partial-escape-transform),always-inline,function(instcombine,simplifycfg)' -jeandle-vm-callback-log=%S/../string-intrinsics/Inputs/layout.cblog -verify-each %s | FileCheck %s --check-prefix=VALUE

; An inactive source suffix may be poison. Check the PEA result before any
; canonicalization that might hide an unmasked condition. Both the failure
; condition and the next active value must ignore Fits after an earlier failure.
; RAW-LABEL: define i32 @encode_poison_suffix(
; RAW-NOT: @jeandle.new_array
; RAW-NOT: @jeandle.encode_array
; RAW: [[FITS0:%.*]] = icmp ule i16 %first, 255
; RAW: [[ACTIVE0:%.*]] = select i1 true, i1 [[FITS0]], i1 false
; RAW: [[FITS1:%.*]] = icmp ule i16 %later, 255
; RAW: [[BAD1:%.*]] = xor i1 [[FITS1]], true
; RAW: [[FAIL1:%.*]] = select i1 [[ACTIVE0]], i1 [[BAD1]], i1 false
; RAW: select i1 [[FAIL1]], i32 1,
; RAW: [[ACTIVE1:%.*]] = select i1 [[ACTIVE0]], i1 [[FITS1]], i1 false
; RAW: select i1 [[ACTIVE1]], i32 {{.*}}, i32
; RAW: ret i32

; VALUE-LABEL: define i32 @failed_prefix_and_suffix(
; VALUE-NEXT: entry:
; VALUE-NEXT: ret i32 117901063
; VALUE-LABEL: define i32 @clean_prefix_and_suffix(
; VALUE-NEXT: entry:
; VALUE-NEXT: ret i32 121717060

target datalayout = "e-p:64:64-p1:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.encode_array(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1, i1)
declare i32 @personality(...)

define i32 @encode_poison_suffix(i16 %first, i16 %next, i16 %shift) alwaysinline gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 3, i32 24, i32 16, i32 100, i1 false, i1 false) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 24, i32 16, i32 100, i1 false, i1 false) to label %body unwind label %u
body:
  %later = shl i16 %next, %shift
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 16
  %sp1 = getelementptr i8, ptr addrspace(1) %src, i64 18
  %sp2 = getelementptr i8, ptr addrspace(1) %src, i64 20
  store atomic i16 %first, ptr addrspace(1) %sp unordered, align 2
  store atomic i16 %later, ptr addrspace(1) %sp1 unordered, align 2
  store atomic i16 65, ptr addrspace(1) %sp2 unordered, align 2
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 16
  store atomic i32 117901063, ptr addrspace(1) %dp unordered, align 4
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 3, i1 false, i1 false)
  %cell = load atomic i32, ptr addrspace(1) %dp unordered, align 4
  %result = add i32 %cell, %r
  ret i32 %result
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @failed_prefix_and_suffix() {
entry:
  %r = call i32 @encode_poison_suffix(i16 256, i16 1, i16 16)
  ret i32 %r
}

define i32 @clean_prefix_and_suffix() {
entry:
  %r = call i32 @encode_poison_suffix(i16 65, i16 65, i16 0)
  ret i32 %r
}

!java-method-compilation = !{}
