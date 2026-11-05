; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

declare hotspotcc ptr addrspace(1) @jeandle.box(i32, ptr, i64)
declare void @sink_i1(i1)
declare i32 @__gxx_personality_v0(...)

@instanceOopDesc.base_offset_in_bytes = private constant i32 16
@java_lang_boxing_object.value_offset = private constant i32 16
@java_lang_boxing_object.long_value_offset = private constant i32 16

define void @test_semantic_box_strict_eq(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %raw = sext i32 %x to i64
  %a = call hotspotcc ptr addrspace(1) @jeandle.box(
      i32 4, ptr inttoptr (i64 400 to ptr), i64 %raw)
  %b = call hotspotcc ptr addrspace(1) @jeandle.box(
      i32 4, ptr inttoptr (i64 400 to ptr), i64 %raw)
  %eq = icmp eq ptr addrspace(1) %a, %b
  call void @sink_i1(i1 %eq)
  ret void
}

!java-method-compilation = !{}

; Strict C1 must preserve cache identity for two distinct box sites.
; CHECK-LABEL: define void @test_semantic_box_strict_eq
; CHECK: @jeandle.box
; CHECK: @jeandle.box
; CHECK: icmp eq ptr addrspace(1)
