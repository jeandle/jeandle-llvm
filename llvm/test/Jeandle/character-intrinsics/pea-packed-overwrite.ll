; RUN: opt -S -passes='function(require<partial-escape-analysis>,partial-escape-transform),always-inline,function(instcombine,simplifycfg)' -jeandle-vm-callback-log=%S/../string-intrinsics/Inputs/layout.cblog -verify-each %s | FileCheck %s
; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform' -jeandle-vm-callback-log=%S/../string-intrinsics/Inputs/layout.cblog -verify-each %s | FileCheck %s --check-prefix=FIRST
; RUN: sed 's/e-p:64/E-p:64/;s/16963/16708/' %s | opt -S -passes='function(require<partial-escape-analysis>,partial-escape-transform),always-inline,function(instcombine,simplifycfg)' -jeandle-vm-callback-log=%S/../string-intrinsics/Inputs/layout.cblog -verify-each | FileCheck %s --check-prefix=BE
;
; A complete packed overwrite must not observe the preceding stored SSA
; value, which can become poison when the caller is inlined later.
; BE-LABEL: define i32 @poison_old(
; BE: ret i32 16708

target datalayout = "e-p:64:64-p1:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.encode_array(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1, i1)
declare i32 @personality(...)

define i32 @convert(i16 %first, i16 %second, i16 %shift) alwaysinline gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %body unwind label %u
body:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 16
  %sp1 = getelementptr i8, ptr addrspace(1) %src, i64 18
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 16
  store atomic i16 65, ptr addrspace(1) %sp unordered, align 2
  store atomic i16 66, ptr addrspace(1) %sp1 unordered, align 2
  %old = shl i16 1, %shift
  store atomic i16 %old, ptr addrspace(1) %dp unordered, align 2
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 2, i1 false, i1 false)
  %v = load atomic i16, ptr addrspace(1) %dp unordered, align 2
  %wide = zext i16 %v to i32
  %sum = add i32 %wide, %r
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @poison_old(
; CHECK: ret i32 16963
define i32 @poison_old(i16 %first, i16 %second) {
  %r = call i32 @convert(i16 %first, i16 %second, i16 16)
  ret i32 %r
}



declare hotspotcc i32 @jeandle.string_compress(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)

; CHECK-LABEL: define i32 @string_poison_old(
; CHECK: ret i32 16963
; BE-LABEL: define i32 @string_poison_old(
; BE: ret i32 16708

define i32 @string_poison_old() {
  %r = call i32 @compress(i16 16)
  ret i32 %r
}

define i32 @compress(i16 %shift) alwaysinline gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %body unwind label %u
body:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 16
  %sp1 = getelementptr i8, ptr addrspace(1) %src, i64 18
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 16
  store atomic i16 65, ptr addrspace(1) %sp unordered, align 2
  store atomic i16 66, ptr addrspace(1) %sp1 unordered, align 2
  %old = shl i16 1, %shift
  store atomic i16 %old, ptr addrspace(1) %dp unordered, align 2
  %r = call hotspotcc i32 @jeandle.string_compress(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 2, i1 false)
  %v = load atomic i16, ptr addrspace(1) %dp unordered, align 2
  %wide = zext i16 %v to i32
  %sum = add i32 %wide, %r
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}


!java-method-compilation = !{}

; A known-bits failure ends the prefix even when the character is not a
; ConstantInt. Every unwritten packed byte retains its former value.
; CHECK-LABEL: define i32 @known_invalid_bits(
; CHECK: ret i32 1858
; BE-LABEL: define i32 @known_invalid_bits(
; BE: ret i32 16648
define i32 @known_invalid_bits(i16 %value) gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %body unwind label %u
body:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 16
  %sp1 = getelementptr i8, ptr addrspace(1) %src, i64 18
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 16
  store atomic i16 65, ptr addrspace(1) %sp unordered, align 2
  %bad = or i16 %value, 256
  store atomic i16 %bad, ptr addrspace(1) %sp1 unordered, align 2
  %old = add i16 1799, 0
  store atomic i16 %old, ptr addrspace(1) %dp unordered, align 2
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 2, i1 false, i1 false)
  %v = load atomic i16, ptr addrspace(1) %dp unordered, align 2
  %wide = zext i16 %v to i32
  %sum = add i32 %wide, %r
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A later source poison must not flow backwards into an earlier written cell.
; The conversion result is deliberately unused so only the defined byte is
; observed after inlining exposes the poison.
; CHECK-LABEL: define i32 @source_late_poison(
; CHECK: ret i32 65
; BE-LABEL: define i32 @source_late_poison(
; BE: ret i32 65
define i32 @source_late_poison() {
  %r = call i32 @read_first_cell(i16 poison)
  ret i32 %r
}

; FIRST-LABEL: define i32 @read_first_cell(
; FIRST: %[[WIDE:.*]] = zext i8 65 to i32
; FIRST-NEXT: ret i32 %[[WIDE]]
define i32 @read_first_cell(i16 %second) alwaysinline gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %body unwind label %u
body:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 16
  %sp1 = getelementptr i8, ptr addrspace(1) %src, i64 18
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 16
  store atomic i16 65, ptr addrspace(1) %sp unordered, align 2
  store atomic i16 %second, ptr addrspace(1) %sp1 unordered, align 2
  %prefix = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 2, i1 false, i1 false)
  %first = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  %wide = zext i8 %first to i32
  ret i32 %wide
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
