; RUN: opt -S -passes='java-operation-lower<phase=0>' -verify-each %s | FileCheck %s --check-prefix=EARLY
; RUN: opt -S -passes='java-operation-lower<phase=1>,instcombine,simplifycfg' -verify-each %s | FileCheck %s --check-prefix=LOWER

target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16

; EARLY-LABEL: @material_word(
; EARLY: call hotspotcc i16 @jeandle.string_getchar
; EARLY-NOT: load atomic i16
; EARLY: ret i32
; LOWER-LABEL: @material_word(
; LOWER-NOT: @jeandle.string_getchar
; LOWER-NOT: load atomic i8
; LOWER: [[WORD:%.*]] = load atomic i16, ptr addrspace(1) {{.*}} unordered, align 2
; LOWER-NOT: load atomic
; LOWER: [[RESULT:%.*]] = zext i16 [[WORD]] to i32
; LOWER-NEXT: ret i32 [[RESULT]]
define hotspotcc i32 @material_word(ptr addrspace(1) %array, i32 %index) {
 %word = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %array, i32 %index)
 %result = zext i16 %word to i32
 ret i32 %result
}

define private hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) nocapture readonly %array, i32 %index) noinline "lower-phase"="1" nounwind "gc-leaf-function" memory(read) {
entry:
 %base = load i32, ptr @arrayOopDesc.base_offset_in_bytes.byte
 %data = getelementptr inbounds i8, ptr addrspace(1) %array, i32 %base
 %address = getelementptr inbounds i16, ptr addrspace(1) %data, i32 %index
 %character = load atomic i16, ptr addrspace(1) %address unordered, align 2
 ret i16 %character
}
!java-method-compilation = !{}
