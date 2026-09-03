; RUN: not --crash opt -passes="require<partial-escape-analysis>" -jeandle-pea-verify-header-access=fatal -disable-output %s 2>&1 | FileCheck %s

; Fatal-mode verifier coverage for the store path and the no-GEP shape:
; storing the mark word directly through the object pointer is a raw
; object-header access (offset 0 < instanceOopDesc.base_offset_in_bytes).

@instanceOopDesc.base_offset_in_bytes = private constant i32 12

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

declare i32 @__gxx_personality_v0(...)

define void @test_raw_header_store() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  store atomic i64 1, ptr addrspace(1) %o unordered, align 8
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK: LLVM ERROR: PEA: raw object-header memory access (constant byte offset 0 < instanceOopDesc.base_offset_in_bytes 12) in function 'test_raw_header_store'

!java-method-compilation = !{}
