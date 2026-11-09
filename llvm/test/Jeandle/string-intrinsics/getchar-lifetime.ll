; RUN: opt -S -passes='function(repeated-constant-field-folding,early-cse,instcombine,repeated-constant-field-folding)' -jeandle-vm-callback-log=%S/Inputs/stable-getchar.cblog -verify-each %s | FileCheck %s --check-prefixes=CHECK,LE
; RUN: sed 's/e-p:64/E-p:64/' %s | opt -S -passes='function(repeated-constant-field-folding,early-cse,instcombine,repeated-constant-field-folding)' -jeandle-vm-callback-log=%S/Inputs/stable-getchar.cblog -verify-each | FileCheck %s --check-prefixes=CHECK,BE

target datalayout = "e-p:64:64-p1:64:64"

@oop_handle_Stable_0 = external global ptr addrspace(1)
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
declare hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1), i32) nounwind memory(read)

; The stable identity becomes available only after holder store forwarding.
; CSE can then merge the two word reads before the next folding round.
; CHECK-LABEL: @late_stable_getchar
; CHECK-NOT: @jeandle.string_getchar
; LE: ret i32 84516
; BE: ret i32 9546
define i32 @late_stable_getchar(ptr addrspace(1) %holder) {
  %stable = load ptr addrspace(1), ptr @oop_handle_Stable_0
  %slot = getelementptr i8, ptr addrspace(1) %holder, i64 16
  store atomic ptr addrspace(1) %stable, ptr addrspace(1) %slot unordered, align 8
  %array = load atomic ptr addrspace(1), ptr addrspace(1) %slot unordered, align 8
  %data = getelementptr i8, ptr addrspace(1) %array, i64 16
  %first = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %array, i32 0)
  %second = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %array, i32 0)
  %a = zext i16 %first to i32
  %b = zext i16 %second to i32
  %sum = add i32 %a, %b
  ret i32 %sum
}

; The direct control exercises the named-operation consumer without forwarding.
; CHECK-LABEL: @direct_stable_getchar
; CHECK-NOT: @jeandle.string_getchar
; LE: ret i32 42258
; BE: ret i32 4773
define i32 @direct_stable_getchar() {
  %stable = load ptr addrspace(1), ptr @oop_handle_Stable_0
  %data = getelementptr i8, ptr addrspace(1) %stable, i64 16
  %word = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %stable, i32 0)
  %result = zext i16 %word to i32
  ret i32 %result
}

!java-method-compilation = !{}
