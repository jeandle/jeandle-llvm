; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Store i32 into a virtual's slot, load i16 at the same byte offset. This is a
; narrowing (sub-width) read of a wider stored field. PEA does not support
; sub-slot / narrowing loads — the load bails to ineligible and the object
; materializes: alloc, store, and load survive intact, no coercion synthesized.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

declare i32 @__gxx_personality_v0(...)

define i16 @test_coerce_i32_to_i16_off0() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
         to label %normal unwind label %unwind

normal:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
  store atomic i32 305419896, ptr addrspace(1) %slot unordered, align 4
  %v = load atomic i16, ptr addrspace(1) %slot unordered, align 2
  ret i16 %v

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i16 @test_coerce_i32_to_i16_off0()
; CHECK: jeandle.new_instance
; CHECK: store atomic i32
; CHECK: load atomic i16
; CHECK-NOT: pea.coerce
; CHECK: ret i16

!java-method-compilation = !{}
