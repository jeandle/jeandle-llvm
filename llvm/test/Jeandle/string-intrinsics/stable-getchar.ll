; RUN: opt -S -passes='repeated-constant-field-folding' -jeandle-vm-callback-log=%S/Inputs/stable-getchar.cblog -verify-each %s | FileCheck %s --check-prefixes=CHECK,LE
; RUN: sed 's/e-p:64/E-p:64/' %s | opt -S -passes='repeated-constant-field-folding' -jeandle-vm-callback-log=%S/Inputs/stable-getchar.cblog -verify-each | FileCheck %s --check-prefixes=CHECK,BE

target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.length_offset_in_bytes = constant i32 12
@oop_handle_Stable_0 = external global ptr addrspace(1)
@oop_handle_Mutable_1 = external global ptr addrspace(1)
@oop_handle_Partial_2 = external global ptr addrspace(1)
declare i32 @jeandle.arraylength(ptr addrspace(1))
declare hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1), i32) nounwind memory(read)

; The named operation preserves getChar semantics, not a proof of stability.
; Both byte reads require independent VM callback authorization.
; CHECK-LABEL: @stable_getchar(
; CHECK-NOT: load atomic i16
; CHECK-NOT: @jeandle.string_getchar
; LE: ret i16 -23278
; BE: ret i16 4773
define i16 @stable_getchar() {
  %a = load ptr addrspace(1), ptr @oop_handle_Stable_0
  %p = getelementptr i8, ptr addrspace(1) %a, i64 16
  %c = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 0)
  ret i16 %c
}

; A callback-folded condition prunes the opaque incoming index before folding.
; CHECK-LABEL: @later_constant_index(
; CHECK-NOT: load atomic i16
; CHECK-NOT: @jeandle.string_getchar
; LE: ret i16 -23278
; BE: ret i16 4773
define i16 @later_constant_index(i32 %unknown) {
entry:
  %a = load ptr addrspace(1), ptr @oop_handle_Stable_0
  %n = call i32 @jeandle.arraylength(ptr addrspace(1) %a)
  %known = icmp eq i32 %n, 2
  br i1 %known, label %left, label %right
left:
  br label %join
right:
  br label %join
join:
  %index = phi i32 [ 0, %left ], [ %unknown, %right ]
  %data = getelementptr i8, ptr addrspace(1) %a, i64 16
  %p = getelementptr i16, ptr addrspace(1) %data, i32 %index
  %c = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 %index)
  ret i16 %c
}

; Ordinary wide byte loads retain the existing conservative width rule.
; CHECK-LABEL: @unmarked(
; CHECK: load atomic i16
; CHECK: ret i16 %c
define i16 @unmarked() {
  %a = load ptr addrspace(1), ptr @oop_handle_Stable_0
  %p = getelementptr i8, ptr addrspace(1) %a, i64 16
  %c = load atomic i16, ptr addrspace(1) %p unordered, align 2
  ret i16 %c
}

; CHECK-LABEL: @mutable(
; CHECK: call hotspotcc i16 @jeandle.string_getchar
; CHECK: ret i16 %c
define i16 @mutable() {
  %a = load ptr addrspace(1), ptr @oop_handle_Mutable_1
  %p = getelementptr i8, ptr addrspace(1) %a, i64 16
  %c = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 0)
  ret i16 %c
}

; The first byte alone cannot authorize folding the word.
; CHECK-LABEL: @partial_authority(
; CHECK: call hotspotcc i16 @jeandle.string_getchar
; CHECK: ret i16 %c
define i16 @partial_authority() {
  %a = load ptr addrspace(1), ptr @oop_handle_Partial_2
  %p = getelementptr i8, ptr addrspace(1) %a, i64 16
  %c = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 0)
  ret i16 %c
}

; CHECK-LABEL: @unknown_index(
; CHECK: call hotspotcc i16 @jeandle.string_getchar
; CHECK: ret i16 %c
define i16 @unknown_index(i32 %index) {
  %a = load ptr addrspace(1), ptr @oop_handle_Stable_0
  %data = getelementptr i8, ptr addrspace(1) %a, i64 16
  %p = getelementptr i16, ptr addrspace(1) %data, i32 %index
  %c = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 %index)
  ret i16 %c
}
!java-method-compilation = !{}

; CHECK-LABEL: @negative_index(
; CHECK: call hotspotcc i16 @jeandle.string_getchar
; CHECK: ret i16 %c
define i16 @negative_index() {
  %a = load ptr addrspace(1), ptr @oop_handle_Stable_0
  %c = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 -1)
  ret i16 %c
}

; CHECK-LABEL: @overflow_index(
; CHECK: call hotspotcc i16 @jeandle.string_getchar
; CHECK: ret i16 %c
define i16 @overflow_index() {
  %a = load ptr addrspace(1), ptr @oop_handle_Stable_0
  %c = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 2147483647)
  ret i16 %c
}

; CHECK-LABEL: @bundled(
; CHECK: call hotspotcc i16 @jeandle.string_getchar
; CHECK: ret i16 %c
define i16 @bundled() {
  %a = load ptr addrspace(1), ptr @oop_handle_Stable_0
  %c = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 0) [ "deopt"(i32 9) ]
  ret i16 %c
}

; CHECK-LABEL: @wrong_cc(
; CHECK: call i16 @jeandle.string_getchar
; CHECK: ret i16 %c
define i16 @wrong_cc() {
  %a = load ptr addrspace(1), ptr @oop_handle_Stable_0
  %c = call i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 0)
  ret i16 %c
}

; CHECK-LABEL: @musttail_arg(
; CHECK: musttail call hotspotcc i16 @jeandle.string_getchar
; CHECK-NEXT: ret i16 %c
define hotspotcc i16 @musttail_arg(ptr addrspace(1) %unused, i32 %index) {
  %a = load ptr addrspace(1), ptr @oop_handle_Stable_0
  %c = musttail call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 0)
  ret i16 %c
}
