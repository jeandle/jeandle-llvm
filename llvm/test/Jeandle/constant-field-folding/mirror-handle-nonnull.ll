; RUN: opt -S -verify-each -passes=constant-field-folding -jeandle-vm-callback-log=%S/Inputs/mirror-handle-nonnull.cblog %s | FileCheck %s --check-prefix=FOLD
; RUN: opt -S -verify-each -passes='constant-field-folding,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/Inputs/mirror-handle-nonnull.cblog %s | FileCheck %s --check-prefix=CLEAN

@oop_handle_Class_0 = external global ptr addrspace(1)
@oop_handle_Primitive_1 = external global ptr addrspace(1)
@oop_handle_Unknown_2 = external global ptr addrspace(1)
@unrecognized_handle = external global ptr addrspace(1)
declare hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1))

; A confirmed mirror at oop id zero is non-null before the query as well.
; FOLD-LABEL: @reference_guard(
; FOLD: %mirror = load ptr addrspace(1), ptr @oop_handle_Class_0, align 8, !nonnull
; FOLD-NOT: call
; FOLD: %reference = icmp ne ptr inttoptr (i64 123 to ptr), null
; CLEAN-LABEL: @reference_guard(
; CLEAN-NEXT: entry:
; CLEAN-NEXT: ret i32 1
define i32 @reference_guard() {
entry:
  %mirror = load ptr addrspace(1), ptr @oop_handle_Class_0, align 8
  %null = icmp eq ptr addrspace(1) %mirror, null
  br i1 %null, label %fail, label %query
fail:
  ret i32 -1
query:
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  %reference = icmp ne ptr %klass, null
  %result = zext i1 %reference to i32
  ret i32 %result
}

; A known-null represented Klass still comes from a non-null primitive mirror.
; FOLD-LABEL: @primitive_guard(
; FOLD: %mirror = load ptr addrspace(1), ptr @oop_handle_Primitive_1, align 8, !nonnull
; FOLD-NOT: call
; FOLD: %reference = icmp ne ptr null, null
; CLEAN-LABEL: @primitive_guard(
; CLEAN-NEXT: entry:
; CLEAN-NEXT: ret i32 0
define i32 @primitive_guard() {
entry:
  %mirror = load ptr addrspace(1), ptr @oop_handle_Primitive_1, align 8
  %null = icmp eq ptr addrspace(1) %mirror, null
  br i1 %null, label %fail, label %query
fail:
  ret i32 -1
query:
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  %reference = icmp ne ptr %klass, null
  %result = zext i1 %reference to i32
  ret i32 %result
}

; An unavailable callback does not authorize any fact about the source load.
; FOLD-LABEL: @unavailable_guard(
; FOLD: %mirror = load ptr addrspace(1), ptr @oop_handle_Unknown_2, align 8{{$}}
; FOLD: call hotspotcc ptr @jeandle.load_mirror_klass
; CLEAN-LABEL: @unavailable_guard(
; CLEAN: %mirror = load ptr addrspace(1), ptr @oop_handle_Unknown_2, align 8{{$}}
; CLEAN: icmp eq ptr addrspace(1) %mirror, null
; CLEAN: br i1
; CLEAN: call hotspotcc ptr @jeandle.load_mirror_klass
define i32 @unavailable_guard() {
entry:
  %mirror = load ptr addrspace(1), ptr @oop_handle_Unknown_2, align 8
  %null = icmp eq ptr addrspace(1) %mirror, null
  br i1 %null, label %fail, label %query
fail:
  ret i32 -1
query:
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  %reference = icmp ne ptr %klass, null
  %result = zext i1 %reference to i32
  ret i32 %result
}

; Ordinary heap loads do not have the constant handle lifetime guarantee.
; FOLD-LABEL: @unsupported_source(
; FOLD: %mirror = load ptr addrspace(1), ptr @unrecognized_handle, align 8{{$}}
; FOLD: call hotspotcc ptr @jeandle.load_mirror_klass
; CLEAN-LABEL: @unsupported_source(
; CLEAN: %mirror = load ptr addrspace(1), ptr @unrecognized_handle, align 8{{$}}
; CLEAN: icmp eq ptr addrspace(1) %mirror, null
; CLEAN: br i1
; CLEAN: call hotspotcc ptr @jeandle.load_mirror_klass
define i32 @unsupported_source() {
entry:
  %mirror = load ptr addrspace(1), ptr @unrecognized_handle, align 8
  %null = icmp eq ptr addrspace(1) %mirror, null
  br i1 %null, label %fail, label %query
fail:
  ret i32 -1
query:
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  %reference = icmp ne ptr %klass, null
  %result = zext i1 %reference to i32
  ret i32 %result
}

; Freeze can choose another value when the select condition is poison.
; FOLD-LABEL: @frozen_source(
; FOLD: %source = load ptr addrspace(1), ptr @oop_handle_Class_0, align 8{{$}}
; FOLD: %mirror = freeze ptr addrspace(1) %selected
; FOLD: call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
; CLEAN-LABEL: @frozen_source(
define ptr @frozen_source(i1 %condition) {
  %source = load ptr addrspace(1), ptr @oop_handle_Class_0, align 8
  %selected = select i1 %condition, ptr addrspace(1) %source, ptr addrspace(1) %source
  %mirror = freeze ptr addrspace(1) %selected
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  ret ptr %klass
}

; Folding a known merged identity does not annotate its separate source loads.
; FOLD-LABEL: @merged_source(
; FOLD: %left = load ptr addrspace(1), ptr @oop_handle_Class_0, align 8{{$}}
; FOLD: %right = load ptr addrspace(1), ptr @oop_handle_Class_0, align 8{{$}}
; FOLD-NOT: call
; FOLD: ret ptr inttoptr (i64 123 to ptr)
; CLEAN-LABEL: @merged_source(
define ptr @merged_source(i1 %condition) {
  %left = load ptr addrspace(1), ptr @oop_handle_Class_0, align 8
  %right = load ptr addrspace(1), ptr @oop_handle_Class_0, align 8
  %mirror = select i1 %condition, ptr addrspace(1) %left, ptr addrspace(1) %right
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  ret ptr %klass
}

!java-method-compilation = !{}
