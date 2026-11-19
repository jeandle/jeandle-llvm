; RUN: opt -S -verify-each -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/klass-queries.cblog %s | FileCheck %s

declare hotspotcc i32 @jeandle.klass_modifiers(ptr)
declare hotspotcc i32 @jeandle.klass_access_flags(ptr, i32)
declare hotspotcc ptr @jeandle.klass_super(ptr)
declare hotspotcc ptr addrspace(1) @jeandle.klass_mirror(ptr)

; CHECK-LABEL: @modifiers(
; CHECK-NEXT: ret i32 17
define i32 @modifiers() {
  %flags = call hotspotcc i32 @jeandle.klass_modifiers(ptr inttoptr (i64 123 to ptr))
  ret i32 %flags
}

; Zero modifiers are a known answer, independently of callback availability.
; CHECK-LABEL: @zero_modifiers(
; CHECK-NEXT: ret i32 0
define i32 @zero_modifiers() {
  %flags = call hotspotcc i32 @jeandle.klass_modifiers(ptr inttoptr (i64 234 to ptr))
  ret i32 %flags
}

; CHECK-LABEL: @unavailable_modifiers(
; CHECK: call hotspotcc i32 @jeandle.klass_modifiers
define i32 @unavailable_modifiers() {
  %flags = call hotspotcc i32 @jeandle.klass_modifiers(ptr inttoptr (i64 345 to ptr))
  ret i32 %flags
}

; Written class-file flags and the hidden bit are stable semantic queries.
; CHECK-LABEL: @written_flags(
; CHECK-NEXT: ret i32 17
define i32 @written_flags() {
  %flags = call hotspotcc i32 @jeandle.klass_access_flags(ptr inttoptr (i64 123 to ptr), i32 32767)
  ret i32 %flags
}

; CHECK-LABEL: @zero_flags(
; CHECK-NEXT: ret i32 0
define i32 @zero_flags() {
  %flags = call hotspotcc i32 @jeandle.klass_access_flags(ptr inttoptr (i64 123 to ptr), i32 512)
  ret i32 %flags
}

; CHECK-LABEL: @hidden_flags(
; CHECK-NEXT: ret i32 67108864
define i32 @hidden_flags() {
  %flags = call hotspotcc i32 @jeandle.klass_access_flags(ptr inttoptr (i64 456 to ptr), i32 67108864)
  ret i32 %flags
}

; CHECK-LABEL: @empty_mask(
; CHECK-NEXT: ret i32 0
define i32 @empty_mask() {
  %flags = call hotspotcc i32 @jeandle.klass_access_flags(ptr inttoptr (i64 123 to ptr), i32 0)
  ret i32 %flags
}

; CHECK-LABEL: @unavailable_flags(
; CHECK: call hotspotcc i32 @jeandle.klass_access_flags
define i32 @unavailable_flags() {
  %flags = call hotspotcc i32 @jeandle.klass_access_flags(ptr inttoptr (i64 345 to ptr), i32 32767)
  ret i32 %flags
}

; Flags outside the stable mask can change after compilation.
; CHECK-LABEL: @mutable_flags(
; CHECK: call hotspotcc i32 @jeandle.klass_access_flags
define i32 @mutable_flags() {
  %flags = call hotspotcc i32 @jeandle.klass_access_flags(ptr inttoptr (i64 123 to ptr), i32 65536)
  ret i32 %flags
}

; CHECK-LABEL: @all_flags(
; CHECK: call hotspotcc i32 @jeandle.klass_access_flags
define i32 @all_flags() {
  %flags = call hotspotcc i32 @jeandle.klass_access_flags(ptr inttoptr (i64 123 to ptr), i32 -1)
  ret i32 %flags
}

; CHECK-LABEL: @dynamic_mask(
; CHECK: call hotspotcc i32 @jeandle.klass_access_flags
define i32 @dynamic_mask(i32 %mask) {
  %flags = call hotspotcc i32 @jeandle.klass_access_flags(ptr inttoptr (i64 123 to ptr), i32 %mask)
  ret i32 %flags
}

; LVI can prove a constant semantic mask only on the guarded path.
; CHECK-LABEL: @guarded_mask(
; CHECK: known:
; CHECK-NEXT: ret i32 0
define i32 @guarded_mask(i32 %mask) {
  %same = icmp eq i32 %mask, 512
  br i1 %same, label %known, label %other
known:
  %flags = call hotspotcc i32 @jeandle.klass_access_flags(ptr inttoptr (i64 123 to ptr), i32 %mask)
  ret i32 %flags
other:
  ret i32 -1
}

; CHECK-LABEL: @superclass(
; CHECK-NEXT: ret ptr inttoptr (i64 234 to ptr)
define ptr @superclass() {
  %super = call hotspotcc ptr @jeandle.klass_super(ptr inttoptr (i64 123 to ptr))
  ret ptr %super
}

; Object and interfaces have known null superclasses.
; CHECK-LABEL: @null_superclass(
; CHECK-NEXT: ret ptr null
define ptr @null_superclass() {
  %super = call hotspotcc ptr @jeandle.klass_super(ptr inttoptr (i64 234 to ptr))
  ret ptr %super
}

; CHECK-LABEL: @unavailable_superclass(
; CHECK: call hotspotcc ptr @jeandle.klass_super
define ptr @unavailable_superclass() {
  %super = call hotspotcc ptr @jeandle.klass_super(ptr inttoptr (i64 345 to ptr))
  ret ptr %super
}

; CHECK-LABEL: @superclass_mirror(
; CHECK-NOT: call
; CHECK: load ptr addrspace(1), ptr @oop_handle_Super_8
; CHECK-NEXT: ret ptr addrspace(1)
define ptr addrspace(1) @superclass_mirror() {
  %super = call hotspotcc ptr @jeandle.klass_super(ptr inttoptr (i64 123 to ptr))
  %mirror = call hotspotcc ptr addrspace(1) @jeandle.klass_mirror(ptr %super)
  ret ptr addrspace(1) %mirror
}

; CHECK-LABEL: @null_queries(
; CHECK: call hotspotcc i32 @jeandle.klass_modifiers(ptr null)
; CHECK: call hotspotcc i32 @jeandle.klass_access_flags(ptr null, i32 512)
; CHECK: call hotspotcc ptr @jeandle.klass_super(ptr null)
define ptr @null_queries() {
  %m = call hotspotcc i32 @jeandle.klass_modifiers(ptr null)
  %a = call hotspotcc i32 @jeandle.klass_access_flags(ptr null, i32 512)
  %s = call hotspotcc ptr @jeandle.klass_super(ptr null)
  ret ptr %s
}

; CHECK-LABEL: @dynamic_queries(
; CHECK: call hotspotcc i32 @jeandle.klass_modifiers
; CHECK: call hotspotcc i32 @jeandle.klass_access_flags
; CHECK: call hotspotcc ptr @jeandle.klass_super
define ptr @dynamic_queries(ptr %klass) {
  %m = call hotspotcc i32 @jeandle.klass_modifiers(ptr %klass)
  %a = call hotspotcc i32 @jeandle.klass_access_flags(ptr %klass, i32 512)
  %s = call hotspotcc ptr @jeandle.klass_super(ptr %klass)
  ret ptr %s
}

!java-method-compilation = !{}
