; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/782_semantic_box_strict_cache_eq.cblog %s | FileCheck %s

; Equality between two distinct semantic box sites must preserve the real
; valueOf cache semantics. PEA cannot replace the pointer comparison with a
; payload comparison: equal values share identity only while cache-backed.

declare hotspotcc ptr addrspace(1) @jeandle.box(i32, ptr, i64)

@instanceOopDesc.base_offset_in_bytes = private constant i32 16
@java_lang_boxing_object.value_offset = private constant i32 16
@java_lang_boxing_object.long_value_offset = private constant i32 16

define i1 @strict_integer_eq(i64 %raw.a, i64 %raw.b) gc "hotspotgc" {
entry:
  %a = call hotspotcc ptr addrspace(1) @jeandle.box(
      i32 4, ptr inttoptr (i64 400 to ptr), i64 %raw.a)
  %b = call hotspotcc ptr addrspace(1) @jeandle.box(
      i32 4, ptr inttoptr (i64 400 to ptr), i64 %raw.b)
  %eq = icmp eq ptr addrspace(1) %a, %b
  ret i1 %eq
}

define i1 @strict_long_ne(i64 %raw.a, i64 %raw.b) gc "hotspotgc" {
entry:
  %a = call hotspotcc ptr addrspace(1) @jeandle.box(
      i32 5, ptr inttoptr (i64 500 to ptr), i64 %raw.a)
  %b = call hotspotcc ptr addrspace(1) @jeandle.box(
      i32 5, ptr inttoptr (i64 500 to ptr), i64 %raw.b)
  %ne = icmp ne ptr addrspace(1) %a, %b
  ret i1 %ne
}

define i1 @strict_boolean_eq(i64 %raw.a, i64 %raw.b) gc "hotspotgc" {
entry:
  %a = call hotspotcc ptr addrspace(1) @jeandle.box(
      i32 0, ptr inttoptr (i64 100 to ptr), i64 %raw.a)
  %b = call hotspotcc ptr addrspace(1) @jeandle.box(
      i32 0, ptr inttoptr (i64 100 to ptr), i64 %raw.b)
  %eq = icmp eq ptr addrspace(1) %a, %b
  ret i1 %eq
}

define i1 @strict_byte_eq(i64 %raw.a, i64 %raw.b) gc "hotspotgc" {
entry:
  %a = call hotspotcc ptr addrspace(1) @jeandle.box(
      i32 1, ptr inttoptr (i64 200 to ptr), i64 %raw.a)
  %b = call hotspotcc ptr addrspace(1) @jeandle.box(
      i32 1, ptr inttoptr (i64 200 to ptr), i64 %raw.b)
  %eq = icmp eq ptr addrspace(1) %a, %b
  ret i1 %eq
}

!java-method-compilation = !{}

; CHECK-LABEL: define i1 @strict_integer_eq
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.box
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.box
; CHECK: icmp eq ptr addrspace(1)

; CHECK-LABEL: define i1 @strict_long_ne
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.box
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.box
; CHECK: icmp ne ptr addrspace(1)

; CHECK-LABEL: define i1 @strict_boolean_eq
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.box
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.box
; CHECK: icmp eq ptr addrspace(1)

; CHECK-LABEL: define i1 @strict_byte_eq
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.box
; CHECK: call hotspotcc ptr addrspace(1) @jeandle.box
; CHECK: icmp eq ptr addrspace(1)
