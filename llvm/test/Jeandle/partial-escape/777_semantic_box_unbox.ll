; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; The generic semantic JavaOps are enough for PEA to carry a primitive payload:
; no VM callback log or wrapper method body is needed.
declare hotspotcc ptr addrspace(1) @jeandle.box(i32, ptr, i64)
declare hotspotcc i64 @jeandle.unbox(i32, ptr addrspace(1))
declare void @sink_i32(i32)
declare i32 @__gxx_personality_v0(...)

@instanceOopDesc.base_offset_in_bytes = private constant i32 16
@java_lang_boxing_object.value_offset = private constant i32 16
@java_lang_boxing_object.long_value_offset = private constant i32 16

define void @test_semantic_box_unbox(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %raw = sext i32 %x to i64
  %box = call hotspotcc ptr addrspace(1) @jeandle.box(
      i32 4, ptr inttoptr (i64 400 to ptr), i64 %raw)
  %value64 = call hotspotcc i64 @jeandle.unbox(i32 4, ptr addrspace(1) %box)
  %value = trunc i64 %value64 to i32
  call void @sink_i32(i32 %value)
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: define void @test_semantic_box_unbox
; CHECK-NOT: @jeandle.box
; CHECK-NOT: @jeandle.unbox
; CHECK: %pea.box.trunc = trunc i64 %raw to i32
; CHECK: %pea.unbox.sext = sext i32 %pea.box.trunc to i64
; CHECK: call void @sink_i32(i32 %value)
