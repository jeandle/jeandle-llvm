; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/../string-intrinsics/Inputs/layout.cblog -verify-each %s | FileCheck %s
; RUN: sed 's/e-p:64/E-p:64/' %s | opt -S -passes='require<partial-escape-analysis>,partial-escape-transform,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/../string-intrinsics/Inputs/layout.cblog -verify-each | FileCheck %s
;
; A concrete UTF-16 source need not prevent elimination of a bounded local
; destination. The loads stay at the validated operation, with native endian
; byte-pair interpretation, and the result preserves the first invalid character.
target datalayout = "e-p:64:64-p1:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.encode_array(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1, i1)
declare i32 @personality(...)
declare hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1), i32)

; External long sources retain the vector operation; their loads cannot be
; forwarded from a local initialization.
; CHECK-LABEL: @utf1665(
; CHECK: @jeandle.new_array
; CHECK-NOT: pea.copy.elem
; CHECK: @jeandle.encode_array
; CHECK: ret i32

define i32 @utf1665(ptr addrspace(1) %src) gc "hotspotgc" personality ptr @personality {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 65, i32 88, i32 16, i32 100, i1 false, i1 false) to label %body unwind label %u
body:
  %same = icmp eq ptr addrspace(1) %src, %dst
  br i1 %same, label %alias, label %encode
alias:
  ret i32 -1
encode:
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 65, i1 true, i1 false)
  %p = getelementptr i8, ptr addrspace(1) %dst, i64 16
  %b = load atomic i8, ptr addrspace(1) %p unordered, align 1
  %w = zext i8 %b to i32
  %sum = add i32 %w, %r
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
!java-method-compilation = !{}

; Expanding this operation cannot eliminate a destination returned to the
; caller. Preserve the JavaOp and its vector lowering even through PEA.
; CHECK-LABEL: @escaping(
; CHECK: @jeandle.new_array
; CHECK-NOT: load atomic
; CHECK: call hotspotcc i32 @jeandle.encode_array
; CHECK: ret ptr addrspace(1) %dst

define ptr addrspace(1) @escaping(ptr addrspace(1) %src) gc "hotspotgc" personality ptr @personality {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 65, i32 88, i32 16, i32 100, i1 false, i1 false) to label %body unwind label %u
body:
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 65, i1 true, i1 false)
  ret ptr addrspace(1) %dst
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A select may alias the destination. It cannot become a speculative source
; load even when the destination otherwise has only supported uses.
; CHECK-LABEL: @may_alias(
; CHECK: @jeandle.new_array
; CHECK-NOT: pea.copy.elem
; CHECK: call hotspotcc i32 @jeandle.encode_array
; CHECK: ret i32

define i32 @may_alias(ptr addrspace(1) %external, i1 %choose) gc "hotspotgc" personality ptr @personality {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 24, i32 16, i32 100, i1 false, i1 false) to label %body unwind label %u
body:
  %src = select i1 %choose, ptr addrspace(1) %external, ptr addrspace(1) %dst
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 2, i1 true, i1 false)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A local UTF16 byte array beyond the physical element limit can still feed
; a scalar destination. Its ordinary byte stores can forward to the reads.
; CHECK-LABEL: @local_utf1665(
; CHECK: @jeandle.new_array{{.*}}i32 130,
; CHECK-NOT: @jeandle.new_array
; CHECK: load atomic i8
; CHECK-NOT: @jeandle.encode_array
; CHECK: ret i32

define i32 @local_utf1665(i8 %value, i32 %index) gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 130, i32 152, i32 16, i32 100, i1 false, i1 false) to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 65, i32 88, i32 16, i32 100, i1 false, i1 false) to label %body unwind label %u
body:
  %p = getelementptr i8, ptr addrspace(1) %src, i64 16
  store atomic i8 %value, ptr addrspace(1) %p unordered, align 1
  %bounded = and i32 %index, 63
  %wide = zext i32 %bounded to i64
  %scaled = shl i64 %wide, 1
  %offset = add i64 %scaled, 16
  %dynamic = getelementptr i8, ptr addrspace(1) %src, i64 %offset
  store atomic i8 %value, ptr addrspace(1) %dynamic unordered, align 1
  %first = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %src, i32 0)
  %first_wide = zext i16 %first to i32
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 65, i1 true, i1 false)
  %d = getelementptr i8, ptr addrspace(1) %dst, i64 16
  %b = load atomic i8, ptr addrspace(1) %d unordered, align 1
  %v = zext i8 %b to i32
  %sum = add i32 %v, %r
  %result = add i32 %sum, %first_wide
  ret i32 %result
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
