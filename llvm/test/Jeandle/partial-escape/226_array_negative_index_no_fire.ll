; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-pea-verify-header-access=fatal %s | FileCheck %s

; Zero-false-positive guarantee: a constant negative array index on a virtual
; array resolves to a sub-base constant byte offset (scale 8, base 16:
; a[-1] -> offset 8 < instanceOopDesc.base_offset_in_bytes 12). That is the
; abstract interpreter's typed-element GEP shape for a designed
; out-of-bounds case (the runtime throws AIOOBE), NOT a raw header access —
; the verifier must stay silent and keep the conservative materialization.

@instanceOopDesc.base_offset_in_bytes = private constant i32 12

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)

declare i32 @__gxx_personality_v0(...)

define i64 @test_array_negative_index() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 7, i32 72, i32 16, i32 8, i1 false, i1 false)
         to label %n unwind label %u
n:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 16
  %elem = getelementptr inbounds i64, ptr addrspace(1) %base, i64 -1
  %v = load atomic i64, ptr addrspace(1) %elem unordered, align 8
  ret i64 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i64 @test_array_negative_index
; CHECK: jeandle.new_array
; CHECK: load atomic i64
; CHECK: ret i64 %v

!java-method-compilation = !{}
