; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/779_boxed_unbox_call.cblog %s | FileCheck %s

; A non-escaping Integer wrapper is virtualized using IsBoxed(400)=Int. The
; direct intValue call is folded from the tracked first-field value, even when
; the wrapper method has not been inlined yet.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i32 @"java_lang_Integer_intValue()I.123"(ptr addrspace(1))
declare void @sink_i32(i32)
declare i32 @__gxx_personality_v0(...)

@instanceOopDesc.base_offset_in_bytes = private constant i32 16
@java_lang_boxing_object.value_offset = private constant i32 16
@java_lang_boxing_object.long_value_offset = private constant i32 16

define void @test_boxed_unbox_call(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 400 to ptr), i32 16, i1 false)
       to label %cont unwind label %unwind
cont:
  %value = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store i32 %x, ptr addrspace(1) %value
  %r = call hotspotcc i32 @"java_lang_Integer_intValue()I.123"(ptr addrspace(1) %o)
  call void @sink_i32(i32 %r)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The wrapper allocation, payload store, and direct unbox call are all gone;
; the sink receives the original scalar payload.
; CHECK-LABEL: define void @test_boxed_unbox_call
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: java_lang_Integer_intValue
; CHECK-NOT: store i32
; CHECK: call void @sink_i32(i32 %x)

!java-method-compilation = !{}
