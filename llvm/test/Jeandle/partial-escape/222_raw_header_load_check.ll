; RUN: not --crash opt -passes="require<partial-escape-analysis>" -jeandle-pea-verify-header-access=fatal -disable-output %s 2>&1 | FileCheck %s

; PEA frontend-invariant verifier: a raw load at a constant byte offset below
; instanceOopDesc.base_offset_in_bytes (an object-header access) through a
; virtual receiver is a frontend bug — header accesses must live inside
; lower-phase >= 1 JavaOps that PEA folds by name. In fatal mode the analyzer
; aborts instead of silently materializing the virtual object.

@instanceOopDesc.base_offset_in_bytes = private constant i32 12

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

declare i32 @__gxx_personality_v0(...)

define i32 @test_raw_header_load() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %hdr = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %v = load atomic i32, ptr addrspace(1) %hdr unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK: LLVM ERROR: PEA: raw object-header memory access (constant byte offset 8 < instanceOopDesc.base_offset_in_bytes 12) in function 'test_raw_header_load'

!java-method-compilation = !{}
