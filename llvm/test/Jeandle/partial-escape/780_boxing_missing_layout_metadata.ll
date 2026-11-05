; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/779_boxed_unbox_call.cblog %s | FileCheck %s

; Missing wrapper-layout metadata must disable boxing PEA rather than infer a
; payload offset from the generic instance base. Both the semantic JavaOps and
; a legacy wrapper allocation therefore retain real unboxing operations.

declare hotspotcc ptr addrspace(1) @jeandle.box(i32, ptr, i64)
declare hotspotcc i64 @jeandle.unbox(i32, ptr addrspace(1))
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i32 @"java_lang_Integer_intValue()I.123"(ptr addrspace(1))
declare void @sink_i32(i32)
declare i32 @__gxx_personality_v0(...)

@instanceOopDesc.base_offset_in_bytes = private constant i32 16

define void @test_semantic_missing_metadata(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %raw = sext i32 %x to i64
  %box = call hotspotcc ptr addrspace(1) @jeandle.box(
      i32 4, ptr inttoptr (i64 400 to ptr), i64 %raw)
  %value64 = call hotspotcc i64 @jeandle.unbox(i32 4, ptr addrspace(1) %box)
  %value = trunc i64 %value64 to i32
  call void @sink_i32(i32 %value)
  ret void
}

define void @test_legacy_missing_metadata(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %box = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
             ptr inttoptr (i64 400 to ptr), i32 16, i1 false)
         to label %cont unwind label %unwind
cont:
  %value.addr = getelementptr inbounds i8, ptr addrspace(1) %box, i64 16
  store i32 %x, ptr addrspace(1) %value.addr
  %value = call hotspotcc i32 @"java_lang_Integer_intValue()I.123"(
      ptr addrspace(1) %box)
  call void @sink_i32(i32 %value)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}

; CHECK-LABEL: define void @test_semantic_missing_metadata
; CHECK: @jeandle.box
; CHECK: @jeandle.unbox

; CHECK-LABEL: define void @test_legacy_missing_metadata
; CHECK: @jeandle.new_instance
; CHECK: @"java_lang_Integer_intValue()I.123"
